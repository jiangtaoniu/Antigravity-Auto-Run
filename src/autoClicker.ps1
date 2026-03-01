param (
    [string]$vscodePid
)

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Windows.Forms

$automation = [System.Windows.Automation.AutomationElement]

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class Keyboard {
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool IsIconic(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport("kernel32.dll")]
    public static extern uint GetCurrentThreadId();

    [DllImport("user32.dll")]
    public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);

    // ── Idle detection: checks last keyboard/mouse input time ──
    [DllImport("user32.dll")]
    static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);

    [StructLayout(LayoutKind.Sequential)]
    struct LASTINPUTINFO {
        public uint cbSize;
        public uint dwTime;
    }

    /// <summary>
    /// Returns how many milliseconds the user has been idle (no keyboard/mouse activity).
    /// </summary>
    public static uint GetIdleTimeMs() {
        LASTINPUTINFO lii = new LASTINPUTINFO();
        lii.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
        GetLastInputInfo(ref lii);
        return (uint)Environment.TickCount - lii.dwTime;
    }

    public static uint GetWindowProcId(IntPtr hwnd) {
        uint pid;
        GetWindowThreadProcessId(hwnd, out pid);
        return pid;
    }

    public const byte VK_MENU = 0x12; 
    public const byte VK_RETURN = 0x0D; 
    public const uint KEYEVENTF_KEYUP = 0x0002;
    public const int SW_RESTORE = 9;
    public const int SW_MINIMIZE = 6;

    public static void StealthAltEnter(IntPtr targetHwnd, IntPtr fallbackHwnd, bool forceRestoreFallback) {
        IntPtr currentForeground = GetForegroundWindow();
        bool wasMinimized = IsIconic(targetHwnd);
        bool requiresFocusSwitch = (currentForeground != targetHwnd && currentForeground != IntPtr.Zero);

        if (!requiresFocusSwitch && forceRestoreFallback && fallbackHwnd != IntPtr.Zero) {
            requiresFocusSwitch = true;
            currentForeground = fallbackHwnd; // Pretend the user never left the browser!
        }

        if (requiresFocusSwitch) {
             uint dummy1;
             uint foregroundThreadId = GetWindowThreadProcessId(currentForeground, out dummy1);
             uint myThreadId = GetCurrentThreadId();
             
             if (foregroundThreadId != myThreadId) {
                 AttachThreadInput(myThreadId, foregroundThreadId, true);
                 if (wasMinimized) ShowWindow(targetHwnd, SW_RESTORE);
                 SetForegroundWindow(targetHwnd);
                 AttachThreadInput(myThreadId, foregroundThreadId, false);
             } else {
                 if (wasMinimized) ShowWindow(targetHwnd, SW_RESTORE);
                 SetForegroundWindow(targetHwnd);
             }

             // Give Electron 150ms to wake up from background/minimized state and hook the keyboard
             System.Threading.Thread.Sleep(150); 
        }

        keybd_event(VK_MENU, 0, 0, UIntPtr.Zero);
        keybd_event(VK_RETURN, 0, 0, UIntPtr.Zero);
        System.Threading.Thread.Sleep(50);
        keybd_event(VK_RETURN, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
        keybd_event(VK_MENU, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
        System.Threading.Thread.Sleep(50);

        // ── Auto-restore: return focus to whatever app the user was in ──
        if (requiresFocusSwitch) {
             uint dummy2;
             uint foregroundThreadId = GetWindowThreadProcessId(targetHwnd, out dummy2);
             uint myThreadId = GetCurrentThreadId();
             
             if (foregroundThreadId != myThreadId) {
                 AttachThreadInput(myThreadId, foregroundThreadId, true);
                 SetForegroundWindow(currentForeground);
                 AttachThreadInput(myThreadId, foregroundThreadId, false);
             } else {
                 SetForegroundWindow(currentForeground);
             }

             // Re-minimize if it was minimized originally
             if (wasMinimized) {
                  ShowWindow(targetHwnd, SW_MINIMIZE);
             }
        }
    }
}
"@

Write-Host "Starting AutoClicker for VS Code (PID $vscodePid)..."

# Dynamically resolve the IDE's process name from the given PID (handles VS Code, Cursor, VSCodium, Antigravity etc.)
$ideProcessName = "Code"
$parentProc = Get-Process -Id $vscodePid -ErrorAction SilentlyContinue
if ($parentProc) {
    # e.g., "Code", "Cursor", "VSCodium", "Antigravity"
    $ideProcessName = $parentProc.Name
    if ($ideProcessName -match "electron") {
        $ideProcessName = "Antigravity"
    }
    Write-Host "Resolved IDE Process Name: $ideProcessName"
}

# Cache to prevent infinitely re-clicking the same historical buttons in the chat view
$global:clickedIds = New-Object System.Collections.Generic.HashSet[string]

# Warmup flag: first scan pass only caches existing buttons without clicking them
$global:isWarmupDone = $false

# Track the last window the user was actively using outside the IDE
$global:lastNonIdeWindow = [IntPtr]::Zero
$global:lastNonIdeTime = [DateTime]::MinValue

# Track when each pending button was first seen but couldn't be clicked (for timeout fallback)
$global:pendingButtons = New-Object System.Collections.Generic.Dictionary[string,DateTime]

# ═══════════════════════════════════════════════════════════════════════════════
# BLACKLIST: If button text contains ANY of these words, NEVER click it.
# Blacklist takes absolute priority over whitelist to prevent dangerous actions.
# ═══════════════════════════════════════════════════════════════════════════════
$BLOCK_KEYWORDS = @(
    # English danger words
    "deny", "reject", "cancel", "decline", "delete", "remove",
    "disable", "block", "stop", "abort", "don't", "do not",
    "never", "revoke", "sign out", "log out", "uninstall",
    "close", "exit", "quit", "dismiss", "discard", "revert",
    "rollback", "undo", "skip", "ignore",
    # Chinese danger words
    "拒绝", "取消", "删除", "移除", "禁用", "阻止",
    "停止", "退出", "关闭", "卸载", "不允许", "不同意",
    "丢弃", "撤销", "回滚", "忽略", "跳过"
)

# ═══════════════════════════════════════════════════════════════════════════════
# WHITELIST: Fuzzy patterns (case-insensitive via -imatch). If button text
# matches ANY pattern AND passes the blacklist check, it will be auto-clicked.
# Uses broad substring matching so future button variants are auto-covered.
# ═══════════════════════════════════════════════════════════════════════════════
$ALLOW_PATTERNS = @(
    # ─── Tier 1 (High Priority): Direct "allow/accept" semantics ───
    "allow",          # Allow, Allow This Conversation, Allow Always, Allow All
    "accept",         # Accept, Accept All, Accept Word, Accept Changes, Accept & Continue
    "approve",        # Approve, Approve All, Auto Approve
    "authorize",      # Authorize, Authorize GitHub Copilot
    "permit",         # Permit, Permitted
    "grant",          # Grant, Grant Access, Grant Permission

    # ─── Tier 2 (Medium Priority): "continue/run/confirm" semantics ───
    "^run\b",         # Run, Run Command, Run All (anchored to prevent matching 'RunTime Error' etc.)
    "continue",       # Continue, Continue Anyway
    "proceed",        # Proceed, Proceed Anyway
    "confirm",        # Confirm, Confirm All
    "^yes\b",         # Yes, Yes to All (anchored to start)
    "^ok$",           # OK (exact match)
    "^okay$",         # Okay (exact match)
    "trust",          # Trust, Trust the authors, Trust this folder
    "retry",          # Retry
    "resume",         # Resume, resume the conversation
    "always\s",       # Always Allow, Always Run, Always Trust
    # ─── Chinese button text ───
    "允许", "许可", "批准", "确认", "确定", "同意",
    "运行", "继续", "重试", "信任", "接受", "授权",
    "总是允许", "总是运行"
)

while ($true) {
    Start-Sleep -Seconds 1

    $codePids = @()
    if ($ideProcessName) {
        $codePids = Get-Process -Name $ideProcessName -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id
    }

    if ($null -eq $codePids -or $codePids.Count -eq 0) {
        continue
    }

    # Constantly background-track what the user is currently looking at
    $currentHwnd = [Keyboard]::GetForegroundWindow()
    if ($currentHwnd -ne [IntPtr]::Zero) {
        $cProcId = [Keyboard]::GetWindowProcId($currentHwnd)
        if ($codePids -notcontains $cProcId) {
            $global:lastNonIdeWindow = $currentHwnd
            $global:lastNonIdeTime = [DateTime]::Now
        }
    }

    # Find ONLY top-level windows belonging to the IDE process to prevent global OS UI tree traversal freezes
    $targetWindows = @()
    $windowCondition = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ClassNameProperty, "Chrome_WidgetWin_1")
    $windows = $automation::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, $windowCondition)
    foreach ($win in $windows) {
        if ($null -ne $win.Current -and $codePids -contains $win.Current.ProcessId) {
            $targetWindows += $win
        }
    }

    # Then we only search for target buttons inside those specific Electron windows.

    $btnCondition = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
    
    # Only search for buttons inside actual VS Code windows!
    foreach ($win in $targetWindows) {
        $buttons = $win.FindAll([System.Windows.Automation.TreeScope]::Descendants, $btnCondition)
        
        foreach ($btn in $buttons) {
            if ($null -ne $btn -and $null -ne $btn.Current) {
            
                $name = $btn.Current.Name
                $class = $btn.Current.ClassName
                $id = $btn.Current.AutomationId
                $cleanName = $name.Trim()
                
                # DIAGNOSTIC: Print every button we scan in VS Code so the user can send me the log if it fails
                if ($cleanName.Length -gt 0 -and $cleanName.Length -lt 50) {
                    # Write-Host "SCANNING BTN: '$cleanName'"
                }
            
                # Check if we have already processed this specific button instance in the UI tree
                $runtimeIdArray = $btn.GetRuntimeId()
                if ($null -ne $runtimeIdArray) {
                    $runtimeId = $runtimeIdArray -join ','
                    if ($global:clickedIds.Contains($runtimeId)) {
                        continue
                    }
                }

                # ══════════════════════════════════════════════════════════════
                # TWO-STEP FILTER: Blacklist-first, then Whitelist
                # ══════════════════════════════════════════════════════════════

                # Step 1: BLACKLIST CHECK — if button contains any danger word, skip immediately
                $isBlocked = $false
                foreach ($blockWord in $BLOCK_KEYWORDS) {
                    if ($cleanName -imatch [regex]::Escape($blockWord)) {
                        $isBlocked = $true
                        break
                    }
                }
                if ($isBlocked) { continue }

                # Step 2: WHITELIST CHECK — if button matches any allow pattern, proceed to click
                $isAllowed = $false
                foreach ($pattern in $ALLOW_PATTERNS) {
                    if ($cleanName -imatch $pattern) {
                        $isAllowed = $true
                        break
                    }
                }
                if (-not $isAllowed) { continue }

                # ── Button passed both filters — proceed with auto-click logic ──

                    # ── Warmup Pass: first cycle only caches, never clicks ──
                    if (-not $global:isWarmupDone) {
                        if ($null -ne $runtimeIdArray) {
                            $null = $global:clickedIds.Add($runtimeId)
                        }
                        # Skip all clicking / scrolling / focus-stealing for historical buttons
                        continue
                    }
                    
                    Write-Host ">>> TARGET MATCHED: '$cleanName' <<<"

                    # ── Strategy: Try silent methods FIRST, only steal focus as last resort ──

                    # Track whether we successfully clicked it without needing physical keyboard
                    $invokedSoftly = $false

                    # 1st attempt: InvokePattern (completely silent, no focus steal)
                    $invokePattern = $btn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern) -as [System.Windows.Automation.InvokePattern]
                    if ($invokePattern) {
                        try {
                            $invokePattern.Invoke()
                            Write-Host "Invoked $cleanName via InvokePattern (silent)"
                            $invokedSoftly = $true
                        }
                        catch { }
                    }
                
                    # 2nd attempt: LegacyIAccessiblePattern (also silent, no focus steal)
                    if (-not $invokedSoftly) {
                        $legacyPattern = $btn.GetCurrentPattern([System.Windows.Automation.LegacyIAccessiblePattern]::Pattern) -as [System.Windows.Automation.LegacyIAccessiblePattern]
                        if ($legacyPattern) {
                            try {
                                $legacyPattern.DoDefaultAction()
                                Write-Host "Invoked $cleanName via LegacyPattern (silent)"
                                $invokedSoftly = $true
                            }
                            catch { }
                        }
                    }
                
                    # 3rd attempt (LAST RESORT): Keyboard injection - requires focus steal
                    if (-not $invokedSoftly) {
                        # ── Smart Guard: 3-tier decision based on real user activity ──
                        $currentFg = [Keyboard]::GetForegroundWindow()
                        $fgProcId = [Keyboard]::GetWindowProcId($currentFg)
                        $userIsElsewhere = ($currentFg -ne [IntPtr]::Zero) -and ($codePids -notcontains $fgProcId)

                        # Get real keyboard/mouse idle time from Windows API
                        $idleMs = [Keyboard]::GetIdleTimeMs()
                        $idleSec = [math]::Round($idleMs / 1000, 1)

                        # Track how long this button has been pending (for 100s timeout fallback)
                        if ($null -ne $runtimeIdArray) {
                            if (-not $global:pendingButtons.ContainsKey($runtimeId)) {
                                $global:pendingButtons[$runtimeId] = [DateTime]::Now
                            }
                            $pendingSec = ([DateTime]::Now - $global:pendingButtons[$runtimeId]).TotalSeconds
                        } else {
                            $pendingSec = 0
                        }

                        $shouldInject = $false
                        $reason = ""

                        if (-not $userIsElsewhere) {
                            # Case 1: User is in the IDE → safe to inject
                            $shouldInject = $true
                            $reason = "user is in IDE"
                        }
                        elseif ($idleMs -ge 10000) {
                            # Case 2: User is elsewhere but idle > 10s → AFK, safe to inject
                            $shouldInject = $true
                            $reason = "user idle for ${idleSec}s (AFK)"
                        }
                        elseif ($pendingSec -ge 100) {
                            # Case 3: Button pending > 100s → timeout, force inject regardless
                            $shouldInject = $true
                            $reason = "timeout after ${pendingSec}s waiting"
                        }

                        if (-not $shouldInject) {
                            # User is actively typing/mousing in another app, and we haven't timed out yet
                            Write-Host "Skipped '$cleanName' - user active elsewhere (idle ${idleSec}s, pending ${pendingSec}s). Retrying next cycle."
                            continue
                        }

                        Write-Host "Proceeding with keyboard injection for '$cleanName' ($reason)"

                        # Safe to inject - proceed with focus steal + Alt+Enter + auto-restore
                        try {
                            # Bring element into view only when we actually need to inject keystrokes
                            try {
                                $btn.SetFocus()
                                $scrollPattern = $btn.GetCurrentPattern([System.Windows.Automation.ScrollItemPattern]::Pattern) -as [System.Windows.Automation.ScrollItemPattern]
                                if ($scrollPattern) {
                                    $scrollPattern.ScrollIntoView()
                                }
                            }
                            catch { }

                            $hwnd = [IntPtr]($win.Current.NativeWindowHandle)
                            if ($hwnd -ne [IntPtr]::Zero) {
                                $forceRestore = $false
                                if (($global:lastNonIdeWindow -ne [IntPtr]::Zero) -and (([DateTime]::Now - $global:lastNonIdeTime).TotalSeconds -lt 5)) {
                                    $forceRestore = $true
                                    Write-Host "Restoring focus back to user's previous window after injection."
                                }

                                # StealthAltEnter automatically restores focus to the previous foreground window
                                [Keyboard]::StealthAltEnter($hwnd, $global:lastNonIdeWindow, $forceRestore)
                                Write-Host "Sent Stealth Alt+Enter to window $hwnd for '$cleanName' - focus auto-restored"
                            }
                        }
                        catch { }

                        # Clean up pending tracker since we handled it
                        if ($null -ne $runtimeIdArray -and $global:pendingButtons.ContainsKey($runtimeId)) {
                            $null = $global:pendingButtons.Remove($runtimeId)
                        }
                    }
                    # Mark element as clicked so we NEVER process it again, even if it stays in the DOM history forever.
                    if ($null -ne $runtimeIdArray) {
                        $null = $global:clickedIds.Add($runtimeId)
                    }

                    # Sleep less so we can blaze through these faster without causing the script to lag and trigger multiple window bounds
                    Start-Sleep -Milliseconds 200
                }
            }
        }
    }

    # After the first full scan of all windows, mark warmup as complete.
    # From next cycle onward, any NEW button that appears will be clicked immediately.
    if (-not $global:isWarmupDone) {
        $warmupCount = $global:clickedIds.Count
        if ($warmupCount -gt 0) {
            Write-Host "[Warmup] Cached $warmupCount historical buttons. Future new buttons will be clicked."
        }
        $global:isWarmupDone = $true
    }
}
