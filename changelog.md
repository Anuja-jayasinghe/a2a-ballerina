# Change Log
This file contains all the notable changes done to the Ballerina a2a package through the releases.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `a2a:Listener` and `a2a:Service`: a Ballerina program can now serve an
  A2A agent over the HTTP+JSON binding at protocol v1.0. Implement one
  method, `onMessage`; the listener runs `getTask`/`cancelTask`/`listTasks`,
  `sendStreamingMessage`/`subscribeToTask` (SSE), push-notification config
  CRUD, the extended Agent Card, discovery, and version/capability gating
  around it.
- `a2a:TaskUpdater`, the client object `onMessage` drives a task through:
  `working`/`addArtifact`/`complete`/`failed`/`reject`/`requireInput`/`requireAuth`.
- `a2a:TaskStore` and the default `a2a:InMemoryTaskStore` — pluggable task
  storage, enforcing the specification's task state machine and the
  `listTasks` ordering/pagination rules.
- `ListenerConfiguration.extendedAgentCard`, an optional richer card served
  from `GET /extendedAgentCard`; unset, the operation fails with
  `a2a:ExtendedAgentCardNotConfiguredError` rather than the listener
  advertising a capability it cannot back.
- Push-notification config CRUD works end to end (create/get/list/delete),
  though `capabilities.pushNotifications` stays `false` in this release —
  the config is stored, not delivered to; see the package README's Roadmap.
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
