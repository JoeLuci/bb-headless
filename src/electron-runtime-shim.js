// Runtime shim for packages that require("electron") at runtime (e.g. electron-log)
const path = require("path");
const os = require("os");
const { EventEmitter } = require("events");

const userDataPath = path.join(os.homedir(), "Library", "Application Support", "bluebubbles-server");
const paths = { userData: userDataPath, home: os.homedir(), exe: process.execPath };

const app = {
    getPath(name) { return paths[name] || path.join(userDataPath, name); },
    setPath(name, p) { paths[name] = p; },
    getVersion() { return "1.9.9"; },
    getName() { return "BlueBubbles"; },
    isReady() { return true; },
    whenReady() { return Promise.resolve(); },
    on() { return app; },
    once() { return app; },
    requestSingleInstanceLock() { return true; },
    quit() { process.exit(0); },
    exit(code) { process.exit(code || 0); },
    relaunch() { process.exit(0); },
    setBadgeCount() { return false; },
    setLoginItemSettings() {},
    getLoginItemSettings() { return { openAtLogin: false }; },
    show() {}, hide() {}, focus() {},
    dock: { hide() {}, show() {} },
    commandLine: { appendSwitch() {}, hasSwitch() { return false; } },
    isPackaged: true,
};

class BrowserWindow {
    constructor() {
        this.webContents = { send() {}, isDestroyed() { return true; } };
    }
    isMinimized() { return false; }
    minimize() {} restore() {} focus() {} close() {} destroy() {} show() {} hide() {}
}

const nativeTheme = new EventEmitter();
nativeTheme.shouldUseDarkColors = false;
nativeTheme.themeSource = "system";

const nativeImage = {
    createFromPath() {
        const img = { toJPEG() { return Buffer.alloc(0); }, toPNG() { return Buffer.alloc(0); }, toDataURL() { return ""; }, getSize() { return {width:0,height:0}; }, resize() { return img; }, isEmpty() { return true; } };
        return img;
    },
    createEmpty() { return this.createFromPath(); },
    createFromBuffer() { return this.createFromPath(); },
};

module.exports = {
    app,
    BrowserWindow,
    nativeTheme,
    nativeImage,
    systemPreferences: { isTrustedAccessibilityClient() { return true; }, getMediaAccessStatus() { return "granted"; } },
    dialog: {
        showMessageBox(w, o) { if (o?.message) console.log("[dialog]", o.message); return Promise.resolve({ response: 0 }); },
        showMessageBoxSync() { return 0; },
        showErrorBox(t, c) { console.error("[dialog]", t, c); },
    },
    ipcMain: { handle() {}, on() { return this; }, once() { return this; }, removeHandler() {}, removeAllListeners() { return this; } },
    shell: { openExternal() { return Promise.resolve(); } },
    Notification: class { show() {} close() {} on() { return this; } },
};
