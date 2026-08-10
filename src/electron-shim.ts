/**
 * Electron API shim for running BlueBubbles server headless (no GUI).
 * Stubs out all Electron APIs that the server code imports, replacing them
 * with no-ops or sensible Node.js equivalents.
 *
 * Licensed under Apache 2.0 (same as BlueBubbles).
 */

import path from "path";
import os from "os";
import { EventEmitter } from "events";

const userDataPath = path.join(os.homedir(), "Library", "Application Support", "bluebubbles-server");

const paths: Record<string, string> = {
    userData: userDataPath,
    home: os.homedir(),
    appData: path.join(os.homedir(), "Library", "Application Support"),
    exe: process.execPath,
    module: process.execPath,
};

class StubDock {
    hide() {}
    show() {}
    setBadge(_text: string) {}
    getBadge() { return ""; }
    bounce() { return 0; }
    cancelBounce(_id: number) {}
    setIcon() {}
    setMenu() {}
    isVisible() { return false; }
}

class StubCommandLine {
    appendSwitch(_switch: string, _value?: string) {}
    appendArgument(_value: string) {}
    hasSwitch(_switch: string) { return false; }
    getSwitchValue(_switch: string) { return ""; }
}

const themeEmitter = new EventEmitter();

export const app = {
    getPath(name: string): string {
        return paths[name] ?? path.join(userDataPath, name);
    },
    setPath(name: string, p: string) {
        paths[name] = p;
    },
    getVersion(): string {
        return "1.9.9";
    },
    getName(): string {
        return "BlueBubbles";
    },
    isReady(): boolean {
        return true;
    },
    whenReady(): Promise<void> {
        return Promise.resolve();
    },
    on(_event: string, _cb: (...args: any[]) => void) {
        return app;
    },
    once(_event: string, _cb: (...args: any[]) => void) {
        return app;
    },
    requestSingleInstanceLock(): boolean {
        return true;
    },
    releaseSingleInstanceLock() {},
    quit() {
        process.exit(0);
    },
    exit(code = 0) {
        process.exit(code);
    },
    relaunch(_options?: any) {
        console.log("[headless] Relaunch requested — restarting process");
        process.exit(0);
    },
    setBadgeCount(_count: number) { return false; },
    getBadgeCount() { return 0; },
    setLoginItemSettings(_settings: any) {},
    getLoginItemSettings() { return { openAtLogin: false }; },
    show() {},
    hide() {},
    focus() {},
    dock: new StubDock(),
    commandLine: new StubCommandLine(),
    isPackaged: true,
};

export class BrowserWindow {
    webContents = {
        send(_channel: string, ..._args: any[]) {},
        isDestroyed() { return true; },
    };
    isMinimized() { return false; }
    minimize() {}
    restore() {}
    focus() {}
    close() {}
    destroy() {}
    show() {}
    hide() {}
    loadURL(_url: string) { return Promise.resolve(); }
    setMenu() {}
}

export const nativeTheme = {
    shouldUseDarkColors: false,
    themeSource: "system" as string,
    on(event: string, cb: (...args: any[]) => void) {
        themeEmitter.on(event, cb);
        return nativeTheme;
    },
    removeListener(event: string, cb: (...args: any[]) => void) {
        themeEmitter.removeListener(event, cb);
        return nativeTheme;
    },
};

export const systemPreferences = {
    isTrustedAccessibilityClient(_prompt: boolean): boolean {
        return true;
    },
    getMediaAccessStatus(_mediaType: string): string {
        return "granted";
    },
};

export const dialog = {
    showMessageBox(_win: any, _opts: any): Promise<{ response: number }> {
        if (_opts?.message) {
            console.log(`[headless-dialog] ${_opts.title ?? ""}: ${_opts.message} — ${_opts.detail ?? ""}`);
        }
        return Promise.resolve({ response: 0 });
    },
    showMessageBoxSync(_win: any, _opts: any): number {
        return 0;
    },
    showOpenDialog(_win: any, _opts: any): Promise<{ canceled: boolean; filePaths: string[] }> {
        return Promise.resolve({ canceled: true, filePaths: [] });
    },
    showErrorBox(title: string, content: string) {
        console.error(`[headless-dialog] ERROR: ${title}: ${content}`);
    },
};

export const ipcMain = {
    handle(_channel: string, _listener: any) {},
    on(_channel: string, _listener: any) { return ipcMain; },
    once(_channel: string, _listener: any) { return ipcMain; },
    removeHandler(_channel: string) {},
    removeAllListeners(_channel?: string) { return ipcMain; },
};

export const shell = {
    openExternal(_url: string) { return Promise.resolve(); },
    openPath(_path: string) { return Promise.resolve(""); },
};

export const Notification = class {
    show() {}
    close() {}
    on() { return this; }
};

export const nativeImage = {
    createFromPath(_path: string) {
        return {
            toJPEG(_quality: number) { return Buffer.alloc(0); },
            toPNG() { return Buffer.alloc(0); },
            toDataURL() { return ""; },
            getSize() { return { width: 0, height: 0 }; },
            resize(_opts: any) { return nativeImage.createEmpty(); },
            isEmpty() { return true; },
        };
    },
    createEmpty() {
        return nativeImage.createFromPath("");
    },
    createFromBuffer(_buffer: Buffer) {
        return nativeImage.createFromPath("");
    },
};

export type MessageBoxOptions = {
    type?: string;
    buttons?: string[];
    title?: string;
    message?: string;
    detail?: string;
};
