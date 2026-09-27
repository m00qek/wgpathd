'use strict';

// Uppercase error codes carried by Result.err.

// Configuration
export const CONFIG_MISSING_OPTION   = "CONFIG_MISSING_OPTION";
export const CONFIG_INVALID_ROLE     = "CONFIG_INVALID_ROLE";
export const CONFIG_INVALID_OPTION   = "CONFIG_INVALID_OPTION";
export const INTERFACE_MISSING       = "INTERFACE_MISSING";

// Discovery
export const DISCOVERY_FETCH_FAILED  = "DISCOVERY_FETCH_FAILED";
export const DISCOVERY_INVALID_JSON  = "DISCOVERY_INVALID_JSON";
export const DISCOVERY_INVALID_PEERS = "DISCOVERY_INVALID_PEERS";
export const CACHE_SAVE_FAILED       = "CACHE_SAVE_FAILED";

// Commands
export const EXEC_TIMEOUT            = "EXEC_TIMEOUT";

// WireGuard
export const WG_COMMAND_FAILED       = "WG_COMMAND_FAILED";
export const WG_PARSE_FAILED         = "WG_PARSE_FAILED";

// Routing
export const ROUTE_LOOKUP_FAILED     = "ROUTE_LOOKUP_FAILED";

// ubus
export const UBUS_CONNECT_FAILED     = "UBUS_CONNECT_FAILED";
export const UBUS_CALL_FAILED        = "UBUS_CALL_FAILED";
export const UBUS_PUBLISH_FAILED     = "UBUS_PUBLISH_FAILED";

// Publisher
export const PUBLISHER_LISTEN_FAILED = "PUBLISHER_LISTEN_FAILED";
