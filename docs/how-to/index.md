# How-to Guides

How-to guides are recipes. Each one takes you through the steps to reach one specific goal, assuming you already know WireGuard and OpenWrt.

---

## Operators

Roughly in the order you will need them:

- [Preparing the WireGuard Substrate](prepare-substrate.md) - How to set up `wg_hub`, `wg_mesh`, the peer annotations and the hub's forwarding.
- [Installing wgpathd](install.md) - How to build, install and upgrade the package.
- [Configuring the Hub](configure-hub.md) - How to publish discovery from the hub.
- [Configuring a Spoke](configure-spoke.md) - How to run a spoke in observe mode and check the relay path.
- [Moving a Spoke from Observe to Steer](enable-steering.md) - How to let wgpathd move peers to direct paths.
- [Applying Configuration Changes](apply-changes.md) - How to check and reload a changed configuration, and when to restart instead.
- [Tuning Timing Parameters](tune-timing.md) - How to change how fast wgpathd falls back and returns.
- [Checking Mesh Paths in LuCI](check-paths-in-luci.md) - How to see which path each peer uses, and why, on the LuCI status pages.
- [Inspecting Status and Troubleshooting](troubleshoot.md) - How to go from a symptom to its cause.
- [Removing wgpathd](uninstall.md) - How to uninstall and leave the mesh in a known state.

## Developers

- [Running Tests](developer/testing.md) - How to run all tests, one suite, one file or a filtered subset.
- [Building the Package](developer/packaging.md) - How to build and check the `.apk`.
- [Writing Documentation](developer/documentation.md) - How to preview, build and place documentation pages.

### Publishing the Documentation

- [Setting Up Publishing](developer/setup-docs-publishing.md) - How to make the first release publish the versioned site, once.
- [Publishing a New Minor Release](developer/publish-minor-docs.md) - How to publish `/X.Y/`, move `latest` and start the docs branch.
- [Publishing a Patch Release](developer/publish-patch-docs.md) - How to republish a minor from a patch tag and move its docs branch.
- [Fixing the Released Docs](developer/fix-released-docs.md) - How to get a docs fix onto the published version, and what to do when the guard refuses.
- [Republishing a Version](developer/republish-docs.md) - How to rerun a failed or lost publish by hand.
