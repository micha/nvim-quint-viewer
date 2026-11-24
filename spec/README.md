# Viewer specification roadmap

1. **Model and verify the current Definition-link contract.** The initial
   slice is [source navigation](source_navigation.qnt) for a valid export of
   `review` from [the approval example](../examples/approval.qnt).
2. **Replay the verified histories in Neovim.** A thin interpreter drives
   the public plugin entry point and keymaps and records observations. Quint
   judges those observations against the same transition rules.

## Source navigation

The model starts with a fresh export and no viewer open. It opens the export,
selects one of two symbols in the graph, focuses the inspector, and follows
that symbol's **Definition** link (not its selected occurrence link). The
source file may change on disk after opening the viewer and before the jump.

- A fresh jump adds one source pane, retains the graph and inspector, and
  focuses the source at the selected definition's line and column zero.
- A changed source adds no pane, keeps focus in the inspector, and emits one
  warning about the changed fingerprint. The edit itself does not notify.

The model is limited to one clean session, two definitions, one optional
on-disk edit to a still-readable source, and one link attempt. Terminal states
can stutter. It does not model missing files, unsaved buffers, repeated jumps,
changes during a jump, pane layout, other links, or invalid exports.

## Verify and generate histories

From the checkout, run:

```sh
nix develop .#spec -c scripts/check-spec.sh
```

The separate shell supplies Quint 0.33.1, Java, and the pinned Apalache
0.62.4 distribution that Quint uses for TLC. The script runs `quint verify`
with TLC over the complete finite model (no trace-length cap), then runs
three named Quint histories: fresh local definition, fresh operator
definition, and source changed after opening. It checks that each history
emits a trace. These checks verify the model, not the plugin implementation.
Quint can reuse an already-running Apalache server; to use the pinned
version, leave port 8822 free or set `QMODEL_SPEC_ENDPOINT` to another unused
local endpoint (for example, `127.0.0.1:8823`).

To inspect the generated histories, run:

```sh
traces=$(mktemp -d)
nix develop -c quint test spec/source_navigation.qnt --backend=typescript \
  --seed=1 --out-itf="$traces/{test}_{seq}.itf.json"
```

Each ITF state contains `session.request` (`op` and `arg`), the source-change
input, and an expected `session.view`. The initial `init` row describes the
baseline before user actions. The `approval.qnt` destination is an ID for the
exact resolved fixture path, not a basename match. `selected` is a scoped
fixture symbol name, not an exporter-generated ID. Pane roles are sorted and
retain duplicates; notices report severity and reason from that request, not
text already visible in the inspector. Keep generated traces untracked.

## Replay against Neovim

`scripts/check.sh` runs replay after the exporter and viewer smoke tests. To
run only replay, use:

```sh
nix develop -c python3 -B tests/replay_source_navigation.py --worktree
```

Omit `--worktree` to test a fresh installation from committed `HEAD`.
[The Python driver](../tests/replay_source_navigation.py) gives only requests
from the ITF histories to [the Lua interpreter](../tests/replay_source_navigation.lua).
Each history uses a fresh fixture export and a clean headless Neovim session.
The driver feeds the observed view after each request back to Quint, which
executes the same transitions and checks each view. It also keeps the real
stale warning but substitutes the pane, focus, and cursor changes from a
fresh jump. Quint must reject that negative control through the same
assertions. Java and TLC are needed for model verification, not for replay.
