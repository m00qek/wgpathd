// Saves a one-peer discovery cache with the real fs, for the cache tests to run under
// a umask of their choosing: ucode -L <src>/*.uc save_cache.uc PATH; prints the Result.
import * as fs from 'fs';
import * as discovery from 'wgpathd.discovery';

let res = discovery.save_cache(fs, ARGV[0], { 'O0LYRo/RVGHReCajupP1UioYUPELAkI8jPy1rWoazG4=': { direct: '[2001:db8::a]:51820' } });
printf('%J\n', { ok: res.ok, details: res.details });
