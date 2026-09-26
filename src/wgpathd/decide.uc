'use strict';

/**
 * THE pure core: decide(ctl, obs, params, now) -> {ctl', effects}. No I/O, no clock read. Derives roams from obs.cur_endpoint vs ctl.asserted (design R2). All failover logic + all unit tests live here.
 *
 * @module wgpathd.decide
 */

// TODO: implement — see the design record
