/// <reference types="@raycast/api">

/* 🚧 🚧 🚧
 * This file is auto-generated from the extension's manifest.
 * Do not modify manually. Instead, update the `package.json` file.
 * 🚧 🚧 🚧 */

/* eslint-disable @typescript-eslint/ban-types */

type ExtensionPreferences = {}

/** Preferences accessible in all the extension's commands */
declare type Preferences = ExtensionPreferences

declare namespace Preferences {
  /** Preferences accessible in the `menubar` command */
  export type Menubar = ExtensionPreferences & {}
  /** Preferences accessible in the `stalled` command */
  export type Stalled = ExtensionPreferences & {}
}

declare namespace Arguments {
  /** Arguments passed to the `menubar` command */
  export type Menubar = {}
  /** Arguments passed to the `stalled` command */
  export type Stalled = {}
}

