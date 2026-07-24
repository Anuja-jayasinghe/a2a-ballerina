// A2A error types.

# Detail attached to every A2AError.
public type A2AErrorDetail record {|
    # Originating JSON-RPC code, preserved for diagnostics
    int code?;
    # Human-readable error message
    string message?;
    # Structured error details from the server
    json data?;
    json...;
|};

# Base type for every A2A protocol error. Distinct so that `is A2AError`
# reliably matches any of its subtypes, and each subtype below is in turn
# distinguishable from its siblings via `is`.
public type A2AError distinct error<A2AErrorDetail>;

# Each specific error derives from A2AError — adding a new one later means
# adding one line here, nothing else in the codebase changes.
public type TaskNotFoundError distinct A2AError;

public type TaskNotCancelableError distinct A2AError;

public type UnsupportedOperationError distinct A2AError;

public type ContentTypeNotSupportedError distinct A2AError;

public type InvalidAgentResponseError distinct A2AError;

public type VersionNotSupportedError distinct A2AError;

public type PushNotificationNotSupportedError distinct A2AError;

public type A2AInternalError distinct A2AError;
