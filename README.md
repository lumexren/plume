![plume](https://img.shields.io/badge/plume-gray?style=for-the-badge&logo=zig&logoColor=orange)
![License](https://img.shields.io/badge/License-GPL--3.0-orange?style=for-the-badge)
![Stars](https://img.shields.io/gitea/stars/lumexren/plume?gitea_url=https%3A%2F%2Fcodeberg.org&style=for-the-badge&color=DAA520)
![Issues](https://img.shields.io/gitea/issues/open/lumexren/plume?gitea_url=https%3A%2F%2Fcodeberg.org&style=for-the-badge)
![Last Commit](https://img.shields.io/gitea/last-commit/lumexren/plume?gitea_url=https%3A%2F%2Fcodeberg.org&style=for-the-badge&color=F7A41D)

A pure-Zig library providing a native, zero-C-dependency implementation of the D-Bus protocol.

## Installation

Add `plume` to your project using `zig fetch`:

```bash
zig fetch --save https://codeberg.org/lumexren/plume/archive/0.17.x.zip
```

Then in your `build.zig`:

```zig
const plume_dep = b.dependency("plume", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("plume", plume_dep.module("plume"));
```

## Documentation

Comprehensive architecture details, type mappings, client/server guides, and tool usage can be found in the **[WIKI](WIKI.md)**.

More examples are available in [`tests/main.zig`](tests/main.zig), [`tests/concurrency_test.zig`](tests/concurrency_test.zig), and [`tests/playground.zig`](tests/playground.zig).

### Acknowledgments

- **Zig Team** - For creating an amazing systems programming language.
- [**Luxluth**](https://github.com/luxluth) - Original creator of the goose library from which plume was forked and modernized.
- **Community** - For feedback, bug reports, and contributions.

---

<div align="center">

**Built with ❤️ by lumexren**<br>
<sup>forked from <a href="https://github.com/luxluth/goose" target="_blank">luxluth/goose</a></sup>

*Star ⭐ this repo if you find it useful!*<br>
*Join our [Fluxer](https://fluxer.gg/xnTFlhV0) for support and updates!*

This project is licensed under the **GNU General Public License v3.0**. See [LICENSE](./LICENSE) for details.

</div>
