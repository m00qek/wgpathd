# Developer Onboarding

In this tutorial we will run wgpathd's test suite, look at the tests for its decision core, build the OpenWrt package, and check that the package installs cleanly on a fresh OpenWrt. By the end we will have a working development loop and a package file we built ourselves.

Everything runs in Docker containers based on official OpenWrt images. Nothing gets installed on our machine.

---

## Prerequisites

- Docker, with permission to run containers as our user.
- `make`.
- A copy of the wgpathd repository.
- About 6 GB of free disk space for the images, most of it for the OpenWrt SDK, and a network connection for the first run.

## Step 1: Open the repository

We start in the root of the repository:

```bash
cd wgpathd
ls
```

We should see, among others, `src/`, `test/`, `files/`, `openwrt/` and a `Makefile`. The daemon's code is in `src/wgpathd/`; the files the package installs on a router are in `files/`.

## Step 2: Run the whole test suite

```bash
make test
```

The first time, this builds a development image from the OpenWrt rootfs and installs ucode, its modules and the `utest` test runner into it. That takes a few minutes and prints Docker build output. Later runs start in seconds.

Then the tests run. Each dot is one passing test, grouped by bundle, and the run ends with a summary like this:

```
Summary:

  293 successes / 0 failures / 0 errors / 0 skipped / 0 ignored (11945 ms)
  Seed:   1790466118615660777
```

The exact count grows as tests are added. What matters is `0 failures / 0 errors`. Notice the seed: some tests generate random inputs, and the seed identifies this run.

## Step 3: Look at the decision core's tests

wgpathd makes every path decision in one pure function, `decide`. Let's run only its tests, with one line per test:

```bash
make unit MODULES=test/unit/wgpathd/decide_test.uc VERBOSE=1
```

This time we see test names:

```
[test/unit/wgpathd/decide_test.uc] test/unit/wgpathd/decide_test.uc (61 tests)
  [PASS] anchor: echo fails but an authenticated roam promotes with the roam as target
  [PASS] lying hub: a bogus candidate fails its trial and backs off
  [PASS] trial false positive: echo ok but the tunnel never answers
  ...
```

Notice the names such as `anchor` and `lying hub`. Each one is a situation wgpathd must survive, from [When things fail](../explanation/state-machine.md#when-things-fail), so the tests read like that list. The ones starting with `I1`, `I4` or `I5` are the property tests that use random inputs; each number is an invariant listed in [How the core is tested](../explanation/architecture.md#how-the-core-is-tested).

Now let's run just the tests with "roam" in their name:

```bash
make unit FILTER='roam'
```

The summary shows only a dozen or so successes; the tests that did not match are counted as `ignored`. `FILTER` and `MODULES` are how we keep the loop fast while working on one area.

## Step 4: Check the code compiles

```bash
make lint
```

This compiles every ucode file and syntax-checks every shell script. It prints nothing when all is well. CI runs `make lint` and `make test` on every push.

## Step 5: Build the package

```bash
make package
```

The first run builds an image from the OpenWrt SDK and fetches feed metadata; this takes longer than the test image did. At the end we should see a line like:

```
'bin/packages/x86_64/base/wgpathd-0.1.2-r1.apk' -> '/artifacts/wgpathd-0.1.2-r1.apk'
```

Let's confirm the file is there:

```bash
ls bin/
```

```
wgpathd-0.1.2-r1.apk
```

That is the package an operator installs on a hub or a spoke.

## Step 6: Install it on a fresh OpenWrt

```bash
make package-check
```

This rebuilds the package, installs it offline into an OpenWrt rootfs container that already has its dependencies, and runs a list of checks, including an upgrade from an earlier release that loaded firewall rules of its own. Among the lines it prints are these, and it ends with the last one:

```
ok   shipped disabled
     -> err: invalid configuration: CONFIG_INVALID_ROLE (unset)
ok   daemon with default config fails cleanly
     -> FAIL  config: option role must be 'spoke' or 'hub' (is unset)
ok   config check fails cleanly on the example
     -> wgpathd: cannot read status: UBUS_CONNECT_FAILED
ok   status without a daemon fails cleanly
ok   full check passes a valid config without ubus
ok   full check prints the firewall rule the hub needs
ok   init script enables
ok   only install and upgrade may reload fw4
ok   upgrade restarts a running daemon
ok   package scripts parse
ok   package removes cleanly
ok   a release with the fw4 include, its rules loaded
ok   upgrade from a release with the fw4 include
ok   upgrade removed the include
ok   upgrade unloaded its rules
package-check: all passed
```

Notice the three lines starting with `->`. The shipped configuration names no role, and the container has no ubus, so nothing can really start. The check makes sure each tool says so in one clear line instead of crashing. The second one, `FAIL  config: option role must be 'spoke' or 'hub' (is unset)`, is exactly what an operator sees from `service wgpathd check` on a router where wgpathd is installed but not configured yet.

## What we did

We ran the full test suite in an OpenWrt container, looked at the decision core's tests and how they map to the failures wgpathd must survive, narrowed a run with `MODULES` and `FILTER`, built the `.apk` in the OpenWrt SDK, and proved it installs and fails safely on a clean system.

## Where to go next

- [Architecture](../explanation/architecture.md) explains the pure core and the I/O shell that the tests are built around.
- [How to run the tests](../how-to/developer/testing.md) covers `make watch` and the other options.
- [How to build the package](../how-to/developer/packaging.md) covers other OpenWrt releases and changing what is packaged.
- [Make targets](../reference/make-targets.md) lists every target and variable.
