'use strict';

// ok/err Result monad for fallible edges (adopted from luci-sso).

const ResultMethods = {};

export function is(obj) {
	return type(obj) == "object" && proto(obj) == ResultMethods;
};

export function ok(data) {
	return proto({ ok: true, data: data }, ResultMethods);
};

export function err(error, details) {
	return proto({ ok: false, error: error, details: details }, ResultMethods);
};

// Only string details are shown: object details are diagnostics, not log text.
export function describe(res) {
	return (type(res.details) == "string" && length(res.details) > 0)
		? `${res.error} (${res.details})`
		: `${res.error}`;
};
