# Bitferry - file replication/backup automation utility

<div align="right"><i>Ein Backup ist kein Backup</i></div>

The [Bitferry](https://github.com/okhlybov/bitferry) is aimed at establishing the automatized file replication/backup routes between multiple endpoints where the latter can be the local directories, online cloud remotes or portable offline storages.

The intended usage ranges from maintaining simple directory copy to another location (disk, mount point) to complex many-to-many (online/offline) data replication/backup solution utilizing portable media as additional data copy and a means of data propagation between the offsites.

Technically it is a frontend to the [Rclone](https://rclone.org/) and [Restic](https://restic.net/) utilities.

## Features

* Multiplatform (Windows / UNIX / macOSX) operation

* Automatized task-based data processing

* One way / two way data synchronization

* Recursive directory copy / update / synchronize

* Incremental directory backup with snapshotting

* File/repository password-based end-to-end encryption

* Online cloud storage relay

* Offline portable storage (USB flash, HDDs, SSDs etc.) relay

## Use cases

* Maintain an update-only files copy in a separate location on the same site

* Maintain offline secure two way file synchronization between two offsites

* Maintain an incremental files backup on a portable medium with multiple offsite copies of the repository

## Implementation

The Bitferry itself is written in [Ruby](https://www.ruby-lang.org) programming language.

The source code is hosted on [GitHub](https://github.com/okhlybov/bitferry) and the binary releases in form of a GEM package are distributed through the [RubyGems](https://rubygems.org/gems/bitferry) repository channel.

## Runtime prerequisites

* Ruby runtime

* Rclone executable

* Restic executable

## Installation

There are several options available for obtaining Bitferry:

* GEM package

* Platform-specific bundle

### GEM package

Being a Ruby code, the Bitferry requires the platform-specific Ruby runtime, version 3.0 or higher. Next, the platform-specific Rclone and Restic executables are also required to be accessible through the `PATH` directory list or through the respective `RCLONE` and `RESTIC` environment variables.

For Windows, the recommended Ruby vendor is [RubyInstaller](https://rubyinstaller.org/). Any Ruby 3 build should be good; a 32-bit version can be used in either 32 ot 64 -bit Windows. Specifically, this one [Win32 Ruby version 3.2](https://github.com/oneclick/rubyinstaller2/releases/download/RubyInstaller-3.2.3-1/rubyinstaller-3.2.3-1-x86.exe) should be fine. The prerequisite utilities are obtainable form the respective download pages [Rclone](https://github.com/rclone/rclone/releases) and [Restic](https://github.com/restic/restic/releases). As these programs are under active development, it is recommended to grab the latest versions. Note that there is no need to match the bitness of the three components.

For UNIX, the Ruby runtime installation is system-specific. For instance,

- Debian/Ubuntu Linux
  
  ```shell
  sudo apt install ruby rclone restic
  ```
* Arch Linux
  
  ```shell
  sudo pacman -S ruby rclone restic
  ```

Once the platform-specific prerequisites are installed the Bitferry itself is one command away

```shell
gem install bitferry
```

## The rest

Despite all claims the online cloud backup is unreliable and thus it is very unwise to use it as the main (if only) backup solution.
