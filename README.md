# Ballerina A2A Library

[![Build](https://github.com/Anuja-jayasinghe/a2a-ballerina/actions/workflows/build-timestamped-master.yml/badge.svg?branch=main)](https://github.com/Anuja-jayasinghe/a2a-ballerina/actions/workflows/build-timestamped-master.yml)
[![GraalVM Check](https://github.com/Anuja-jayasinghe/a2a-ballerina/actions/workflows/build-with-bal-test-graalvm.yml/badge.svg)](https://github.com/Anuja-jayasinghe/a2a-ballerina/actions/workflows/build-with-bal-test-graalvm.yml)
[![Trivy](https://github.com/Anuja-jayasinghe/a2a-ballerina/actions/workflows/trivy-scan.yml/badge.svg)](https://github.com/Anuja-jayasinghe/a2a-ballerina/actions/workflows/trivy-scan.yml)
[![FOSSA](https://github.com/Anuja-jayasinghe/a2a-ballerina/actions/workflows/fossa_scan.yml/badge.svg)](https://github.com/Anuja-jayasinghe/a2a-ballerina/actions/workflows/fossa_scan.yml)
[![GitHub Last Commit](https://img.shields.io/github/last-commit/Anuja-jayasinghe/a2a-ballerina.svg)](https://github.com/Anuja-jayasinghe/a2a-ballerina/commits/main)
[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)

## Overview

This library provides a Ballerina client for the
[Agent2Agent (A2A) protocol](https://a2a-protocol.org) — the open
standard that lets AI agents built by different teams, in different
languages, discover and call each other over a shared wire protocol.

Given any A2A-compliant agent's URL, `ballerina/a2a` discovers its
capabilities and calls it — send messages, stream responses, manage
tasks, configure push notifications — the same way regardless of which
language, framework, or protocol dialect that agent happens to speak
underneath. Verified end-to-end against real, independently-built agents
in a companion repo,
[`a2a-interop-tests`](https://github.com/Anuja-jayasinghe/a2a-interop-tests),
not just this library's own mocks.

Server/listener support — letting a Ballerina program *be* an A2A agent —
is a deliberately deferred later phase; see the package README's
[Roadmap](ballerina/README.md#roadmap).

## Issues and feature requests

This repository's own [Issues tab](https://github.com/Anuja-jayasinghe/a2a-ballerina/issues)
tracks bugs, feature requests, and open design questions — report or
browse them there.

## Build from the source

### Prerequisites

1. Download and install Java SE Development Kit (JDK) version 21 (from
   one of the following locations).

   - [Oracle](https://www.oracle.com/java/technologies/downloads/)
   - [OpenJDK](https://adoptium.net/)

     > **Note:** Set the `JAVA_HOME` environment variable to the path
     > name of the directory into which you installed JDK.

2. Generate a GitHub access token with read package permissions, then
   set the following `env` variables:

   ```shell
   export packageUser=<Your GitHub Username>
   export packagePAT=<GitHub Personal Access Token>
   ```

### Build options

Execute the commands below to build from the source.

1. To build the package:

   ```bash
   ./gradlew clean build
   ```

2. To run the tests:

   ```bash
   ./gradlew clean test
   ```

3. To run a group of tests:

   ```bash
   ./gradlew clean test -Pgroups=<test_group_names>
   ```

4. To build without the tests:

   ```bash
   ./gradlew clean build -x test
   ```

5. To debug the package with a remote debugger:

   ```bash
   ./gradlew clean build -Pdebug=<port>
   ```

6. To debug with the Ballerina language:

   ```bash
   ./gradlew clean build -PbalJavaDebug=<port>
   ```

7. Publish the generated artifacts to the local Ballerina central
   repository:

   ```bash
   ./gradlew clean build -PpublishToLocalCentral=true
   ```

8. Publish the generated artifacts to the Ballerina central repository:

   ```bash
   ./gradlew clean build -PpublishToCentral=true
   ```

## Contributing

Fork the repository, create a branch per change, and open a pull request
against `main` — the repository's [pull request template](.github/pull_request_template.md)
and [`CODEOWNERS`](.github/CODEOWNERS) are already set up to route review.

## Code of conduct

All contributors are encouraged to read the
[Ballerina Code of Conduct](https://ballerina.io/code-of-conduct).

## Useful links

- Chat live with the Ballerina community via their
  [Discord server](https://discord.gg/ballerinalang).
- Post technical questions on Stack Overflow with the
  [#ballerina](https://stackoverflow.com/questions/tagged/ballerina) tag.
