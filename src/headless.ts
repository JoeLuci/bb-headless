/**
 * Headless entry point for BlueBubbles Server.
 * Runs as a plain Node.js process — no Electron, no WindowServer, no GUI.
 *
 * Licensed under Apache 2.0 (same as BlueBubbles).
 */

import "reflect-metadata";
import "@server/env";

import process from "process";
import fs from "fs";
import yaml from "js-yaml";
import { FileSystem } from "@server/fileSystem";
import { ParseArguments } from "@server/helpers/argParser";
import { Server } from "@server";
import { BrowserWindow } from "electron";
import { isEmpty, safeTrim } from "@server/helpers/utils";
import { getLogger } from "@server/lib/logging/Loggable";

// Load the config file
let cfg = {};
if (fs.existsSync(FileSystem.cfgFile)) {
    cfg = yaml.load(fs.readFileSync(FileSystem.cfgFile, "utf8"));
}

// Parse CLI args and merge with config
const args = ParseArguments(process.argv);
const parsedArgs: Record<string, any> = { ...cfg, ...args };
let isHandlingExit = false;

// Force headless-friendly settings
parsedArgs["headless"] = true;
parsedArgs["hide_dock_icon"] = true;
parsedArgs["start_minimized"] = true;

// Initialize the server with a stub window (prevents null reference in preChecks)
const stubWindow = new BrowserWindow();
Server(parsedArgs, stubWindow as any);
const log = getLogger("Headless");

log.info("Starting BlueBubbles Server in headless mode (no Electron)...");
log.info(`PID: ${process.pid}, User: ${process.env.USER ?? "unknown"}`);

// Single instance lock via pidfile
const pidDir = `/tmp/bb-headless-${process.env.USER ?? "unknown"}`;
const pidFile = `${pidDir}/bb.pid`;
try {
    fs.mkdirSync(pidDir, { recursive: true });
    if (fs.existsSync(pidFile)) {
        const oldPid = parseInt(fs.readFileSync(pidFile, "utf8").trim(), 10);
        try {
            process.kill(oldPid, 0); // Check if alive
            log.error(`BlueBubbles is already running (PID ${oldPid}). Exiting.`);
            process.exit(1);
        } catch {
            // Old process is dead, clean up stale pidfile
        }
    }
    fs.writeFileSync(pidFile, String(process.pid));
} catch (ex: any) {
    log.warn(`Could not create pidfile: ${ex.message}`);
}

const handleExit = async () => {
    if (isHandlingExit) return;
    isHandlingExit = true;

    log.info("Shutting down...");
    if (Server() && !Server().isStopping) {
        await Server().stopServices();
        await Server().stopServerComponents();
    }

    // Clean up pidfile
    try { fs.unlinkSync(pidFile); } catch { /* ignore */ }

    process.exit(0);
};

// Start the server
(async () => {
    try {
        await Server().start();
        log.info("BlueBubbles Server is running headless.");
    } catch (ex: any) {
        log.error(`Failed to start server: ${ex.message}`);
        if (ex?.stack) log.error(ex.stack);
        process.exit(1);
    }
})();

process.on("uncaughtException", error => {
    log.error(`Uncaught Exception: ${error.message}`);
    if (error?.stack) log.error(`Stack: ${error.stack}`);
});

process.on("unhandledRejection", (reason: any) => {
    log.error(`Unhandled Rejection: ${reason?.message ?? reason}`);
});

process.on("SIGTERM", handleExit);
process.on("SIGINT", handleExit);

// CLI command handler (same as original)
const quickStrConvert = (val: string): string | number | boolean => {
    if (val.toLowerCase() === "true") return true;
    if (val.toLowerCase() === "false") return false;
    return val;
};

process.stdin?.on("data", chunk => {
    const line = safeTrim(chunk.toString());
    if (!Server() || isEmpty(line)) return;

    const parts = chunk ? line.split(" ") : [];
    if (isEmpty(parts)) return;

    switch (parts[0].toLowerCase()) {
        case "help":
            console.log("Commands: help, set <key> <value>, show <key>, restart");
            break;
        case "set":
            if (parts.length >= 3) {
                const key = parts[1];
                const val = quickStrConvert(parts.slice(2).join(" "));
                if (Server().repo.hasConfig(key)) {
                    Server().repo.setConfig(key, val);
                    log.info(`Set ${key} = ${val}`);
                } else {
                    log.info(`Unknown config key: ${key}`);
                }
            }
            break;
        case "show":
            if (parts.length >= 2 && Server().repo.hasConfig(parts[1])) {
                log.info(`${parts[1]} = ${Server().repo.getConfig(parts[1])}`);
            }
            break;
        case "restart":
            log.info("Restarting...");
            handleExit();
            break;
        default:
            log.info(`Unknown command: ${parts[0]}`);
    }
});
