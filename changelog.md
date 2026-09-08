# Change Log
This file contains all the notable changes done to the Ballerina a2a package through the releases.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `CredentialProvider` and `InMemoryCredentialStore`, plus an optional
  `credentials` parameter on `Client`, `JsonRpcClient`, `RestClient`, and
  `GrpcClient`. Credentials are keyed by security-scheme name, so one
  client can hold several distinct credentials for one agent, and can
  replace one after construction. Covers API-key-in-header and HTTP
  bearer/basic; OAuth2, OpenID Connect, and mutual TLS remain with
  `clientConfig.auth`.
- `skillSecurityRequirements` and `resolveSecuritySchemes`, for finding out
  which credential a named skill requires and what that requirement
  concretely means.
- `isAuthorizationRequired` and `authorizationPrompt`, for recognising the
  specification's in-task authorization signal (§7.6) and reading the
  agent's explanation of what it needs.
