# Tor Browser & Mullvad Browser for ARM64/aarch64

Stable builds of ![image](https://raw.githubusercontent.com/Botspot/pi-apps/refs/heads/master/apps/Tor/icon-24.png) **Tor Browser** and ![image](https://raw.githubusercontent.com/Botspot/pi-apps/refs/heads/master/apps/Mullvad/icon-24.png) **Mullvad Browser** for ARM64/aarch64 systems (e.g., Raspberry Pi, Apple Silicon, AWS Graviton). Available on [Pi-Apps](https://pi-apps.io).

[![badge](https://github.com/Botspot/pi-apps/blob/master/icons/badge-light.png?raw=true)](https://github.com/Botspot/pi-apps)

###### 🤖 **Automated Builds**: New releases are built automatically via GitHub Actions whenever the Tor Project or Mullvad publish updates.

## Installation

1. Go to the [Releases](../../releases) page
2. Download the latest .tar.xz archive for your browser.
3. Extract it: `tar -xpJf tor-browser-linux-aarch64-*.tar.xz` or `tar -xpJf mullvad-browser-linux-aarch64-*.tar.xz`
4. Go to the browser directory: `cd tor-browser` or `cd mullvad-browser`
5. Run: `./start-*-browser.desktop`

- Add the browser to your desktop's application menu: `./start-*-browser.desktop --register-app`
- Remove it from the application menu: `./start-*-browser.desktop --unregister-app`

Additionally, _.deb_ and _.rpm_ packages may be available if the build provides them.

## License

This repository contains build scripts and configurations. The browsers themselves are subject to their respective licenses:
- **Tor Browser**: Modified Mozilla Public License
- **Mullvad Browser**: Modified Mozilla Public License

Build scripts in this repository are licensed under the MIT License.

## Acknowledgments

- [The Tor Project](https://www.torproject.org/) for Tor Browser
- [Mullvad VPN](https://mullvad.net/) for Mullvad Browser
- The open-source community for tools and inspiration


[![Update Check](https://github.com/ooovlad/tor-mullvad-aarch64/actions/workflows/update-check.yml/badge.svg?branch=main&event=schedule)](https://github.com/ooovlad/tor-mullvad-aarch64/actions/workflows/update-check.yml)
[![Builder for Tor and Mullvad](https://github.com/ooovlad/tor-mullvad-aarch64/actions/workflows/build.yml/badge.svg?branch=main)](https://github.com/ooovlad/tor-mullvad-aarch64/actions/workflows/build.yml)
