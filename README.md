# Bitferry - file replication/backup automation utility

<div align="right"><i>Ein Backup ist kein Backup</i></div>

The [Bitferry](https://github.com/okhlybov/bitferry) is aimed at establishing the automatized file replication/backup routes between multiple endpoints where the latter can be the local directories, online cloud remotes or portable offline storages.

The intended usage ranges from maintaining simple directory copy to another location (disk, mount point) to complex many-to-many (online/offline) data replication/backup solution utilizing portable media as additional data copy and a means of data propagation between the offsites.

Technically it is a frontend to [Rclone](https://rclone.org/) and [Restic](https://restic.net/) utilities.

## Features

* Multiplatform (Windows / UNIX / macOSX) operation

* Automatized task-based data processing

* Recursive directory copy / update / synchronize

* One way / two way data synchronization

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

Being a Ruby code, the Bitferry requires the platform-specific Ruby runtime, version 3.0 or higher.























Despite all claims the online cloud backup is unreliable and thus it is very unwise to use it as the main (if only) backup solution.
