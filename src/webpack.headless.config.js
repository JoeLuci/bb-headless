/**
 * Webpack config for headless (no-Electron) BlueBubbles Server build.
 * Targets plain Node.js and aliases "electron" to our shim module.
 */

const path = require("path");
const { merge } = require("webpack-merge");
const nodeExternals = require("webpack-node-externals");
const baseConfig = require("./webpack.base.config");

module.exports = merge(baseConfig, {
    mode: "production",
    target: "node",
    externals: [
        nodeExternals({
            allowlist: ["electron"],
        }),
        nodeExternals({
            modulesDir: path.resolve(__dirname, '../../../node_modules'),
            allowlist: ["electron"],
        }),
    ],
    entry: {
        headless: "./src/headless.ts"
    },
    resolve: {
        alias: {
            "electron": path.resolve(__dirname, "../src/electron-shim.ts"),
        }
    },
    module: {
        rules: [
            {
                test: /\.tsx?$/,
                exclude: /node_modules/,
                loader: "babel-loader",
                options: {
                    cacheDirectory: true,
                    babelrc: false,
                    presets: [
                        [
                            "@babel/preset-env",
                            { targets: "maintained node versions" }
                        ],
                        "@babel/preset-typescript"
                    ],
                    plugins: [
                        ["@babel/plugin-proposal-decorators", { legacy: true }],
                        [
                            "@babel/plugin-transform-class-properties",
                            { loose: true }
                        ],
                        [
                            "@babel/plugin-transform-private-methods",
                            { loose: true }
                        ],
                        [
                            "@babel/plugin-transform-private-property-in-object",
                            { loose: true }
                        ]
                    ]
                }
            }
        ]
    },
    plugins: []
});
