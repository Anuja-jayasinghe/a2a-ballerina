// A2A error types.

# Detail attached to every A2AError.
public type A2AErrorDetail record {|
    # Human-readable error message
    string message;
    # Originating JSON-RPC code, preserved for diagnostics
    int code?;
    # Structured error details from the server
    json data?;
    json...;
|};

public type TaskNotFoundError error<A2AErrorDetail>;

public type TaskNotCancelableError error<A2AErrorDetail>;

public type UnsupportedOperationError error<A2AErrorDetail>;

public type ContentTypeNotSupportedError error<A2AErrorDetail>;

public type InvalidAgentResponseError error<A2AErrorDetail>;

public type VersionNotSupportedError error<A2AErrorDetail>;

public type PushNotificationNotSupportedError error<A2AErrorDetail>;

public type A2AInternalError error<A2AErrorDetail>;

# Union of every A2A protocol error. Lets callers narrow with a single
# type test rather than checking each subtype individually.
public type A2AError TaskNotFoundError
                    | TaskNotCancelableError
                    | UnsupportedOperationError
                    | ContentTypeNotSupportedError
                    | InvalidAgentResponseError
                    | VersionNotSupportedError
                    | PushNotificationNotSupportedError
                    | A2AInternalError;
