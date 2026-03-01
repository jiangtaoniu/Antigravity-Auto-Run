import * as vscode from 'vscode';
import { spawn, ChildProcess } from 'child_process';
import * as path from 'path';

let clickerProcess: ChildProcess | undefined;
let notificationPoller: NodeJS.Timeout | undefined;
let outputChannel: vscode.OutputChannel;

export function activate(context: vscode.ExtensionContext) {
    outputChannel = vscode.window.createOutputChannel('Auto Approve');
    outputChannel.appendLine('Auto Approve is now active.');

    const startCommand = vscode.commands.registerCommand('auto-approve.start', () => {
        startClicker(context);
        vscode.window.showInformationMessage('Auto Approve: Started.');
    });

    const stopCommand = vscode.commands.registerCommand('auto-approve.stop', () => {
        stopClicker();
        vscode.window.showInformationMessage('Auto Approve: Stopped.');
    });

    context.subscriptions.push(startCommand, stopCommand);

    // Auto-start on load
    startClicker(context);
}

function startClicker(context: vscode.ExtensionContext) {
    if (clickerProcess) {
        return;
    }

    const scriptPath = path.join(context.extensionPath, 'src', 'autoClicker.ps1');
    const pid = process.pid.toString();

    // Encode the command as UTF-16LE Base64 to prevent path corruption on non-English locales.
    const commandToRun = `& '${scriptPath}' -vscodePid ${pid}`;
    const encodedCommand = Buffer.from(commandToRun, 'utf16le').toString('base64');

    clickerProcess = spawn('powershell.exe', [
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-WindowStyle', 'Hidden',
        '-EncodedCommand', encodedCommand
    ]);

    clickerProcess.stdout?.on('data', (data) => {
        const msg = data.toString().trim();
        if (msg) { outputChannel.appendLine(`[PS] ${msg}`); }
    });

    clickerProcess.stderr?.on('data', (data) => {
        const msg = data.toString().trim();
        if (msg) { outputChannel.appendLine(`[ERR] ${msg}`); }
    });

    clickerProcess.on('close', (code) => {
        outputChannel.appendLine(`AutoClicker process exited with code ${code}`);
        clickerProcess = undefined;
    });

    // VS Code Native Notification Poller
    // UIAutomation cannot see inside VS Code's custom Toast Notifications.
    // We use the internal command API to accept the primary action of any active toast.
    if (!notificationPoller) {
        notificationPoller = setInterval(() => {
            vscode.commands.executeCommand('notifications.acceptPrimaryAction').then(undefined, () => { });
        }, 500);
        outputChannel.appendLine('[Extension] Toast Notification Poller started.');
    }
}

function stopClicker() {
    if (clickerProcess) {
        clickerProcess.kill();
        clickerProcess = undefined;
    }

    if (notificationPoller) {
        clearInterval(notificationPoller);
        notificationPoller = undefined;
    }
}

export function deactivate() {
    stopClicker();
}
