# luaia

Luau minifier written in Luau. It parses source into an AST, optimizes it, and
generates compact output.

## Install

### Rokit

Add luaia to `rokit.toml`:

```toml
[tools]
luaia = "matpatz/luaia@0.5.0"
```

Then run:

```sh
rokit install
luaia script.luau
```

Prebuilt binaries are also available on the [GitHub releases page](https://github.com/matpatz/luaia/releases).

### From source

Requires [Lune](https://github.com/lune-org/lune) 0.10.x:

```sh
git clone https://github.com/matpatz/luaia.git
cd luaia
lune run bin/cli.lua script.luau
```

## CLI

```sh
luaia script.luau                  # write minified source to stdout
luaia script.luau -o min.luau      # write to a file
luaia -s 'print("hello")'          # minify inline source
luaia --stdin                      # read source from stdin
luaia script.luau -r               # minify and run with Lune
```

When running from source, replace `luaia` with `lune run bin/cli.lua`.

| Flag | Description |
|------|-------------|
| `-s <source>` | Minify inline source |
| `-o <file>` | Write output to a file |
| `-t` | Print minification time |
| `-r` | Run output with Lune |
| `--no-fold` | Disable constant folding |
| `--no-rename` | Disable local variable renaming |
| `--no-localize` | Disable global localization |
| `--no-bools` | Disable boolean localization |
| `--no-strings` | Disable repeated string localization |
| `--no-dce` | Disable dead-code elimination |
| `--no-inline-single-use` | Disable inlining of constant locals |
| `--table-keys` | Enable table-key renaming |
| `--table-fold` | Enable table constant folding |
| `--pack-locals` | Pack locals into tables |
| `--version` | Print the version |
| `--help` | Print help |

## Library

```lua
local luaia = require("@luaia")

local result, errors = luaia.Minify(source, {
    Rules = {
        MinifyVariables = true,
        ConstantFold = true,
        RemoveRedundantParens = true,
        LocalizeGlobals = true,
        LocalizeBooleans = true,
        LocalizeStrings = true,
        DeadCodeElimination = true,
        RenameTableKeys = false,
        TableConstantFolding = false,
        InlineSingleUse = true,
    },
})
```

`luaia.PackVariables(source)` is a separate lowering pass for scripts that
exceed Luau's 200-local-per-function limit. It is also available as
`--pack-locals`.

## Rules

Most rules are enabled by default. `RenameTableKeys` and
`TableConstantFolding` are disabled by default.

`InlineSingleUse` inlines locals whose value is a constant expression (no
function calls, table literals, or other side effects) into every use site and
drops the declaration, so they fold away entirely. For example:

```lua
local A = 5 + 5
local B = A * 2
print(A, B)
```

minifies to `print(10,20)`.

| Rule | CLI flag | Description |
|------|----------|-------------|
| `MinifyVariables` | `--no-rename` | Rename local variables to short names |
| `ConstantFold` | `--no-fold` | Fold constant expressions |
| `RemoveRedundantParens` | | Remove unnecessary parentheses |
| `LocalizeGlobals` | `--no-localize` | Cache global references in locals |
| `LocalizeBooleans` | `--no-bools` | Localize repeated boolean literals |
| `LocalizeStrings` | `--no-strings` | Store repeated strings in one local table |
| `DeadCodeElimination` | `--no-dce` | Fold dead branches and remove unused locals |
| `InlineSingleUse` | `--no-inline-single-use` | Inline constant locals into their uses |
| `RenameTableKeys` | `--table-keys` | Rename safely isolated table fields |
| `TableConstantFolding` | `--table-fold` | Fold reads from immutable table literals |

Table-key renaming and table constant folding are conservative: values are
left unchanged when mutation, aliasing, escaping, or dynamic access could make
rewriting unsafe.

## Benchmarks

Run the benchmark with:

```sh
lune run benchmarks/run.luau --runs 20 --warmup 5
```

Results below use the default configuration, 100 measured runs, 20 warmup runs,
Lune 0.10.5, and Windows.

| Fixture | Input | Total | Output |
|---------|------:|------:|-------:|
| Tiny | 69 B | 0.093 ms | 31 B |
| Medium | 1.86 KB | 1.638 ms | 1.01 KB |
| Large | 9.94 KB | 8.964 ms | 5.04 KB |

## License

GPLv3. See [LICENSE](LICENSE).
