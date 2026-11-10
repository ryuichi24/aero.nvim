# Scenes

A scene groups **Workspace**, **General**, and **Knowledge base** into a working
context. For example, keep a Work scene with several repositories and research
collections, and a Personal scene with a different set.

The sidebar header shows the active scene. Press Enter on the header to switch
scenes; `a` creates one, `r` renames it, and `d` deletes it. The scene picker also
supports `n` for new, `r` for rename, and `d` for delete.

## Commands

| Command | Action |
| --- | --- |
| `:Aero scene` | Pick a scene |
| `:Aero scene new [name]` | Create a scene and switch to it; prompt when no name is given |
| `:Aero scene switch [name]` | Switch by name or ID; open the picker when omitted |
| `:Aero scene rename [name]` | Prompt for a new name for the named scene, or the current scene |
| `:Aero scene delete [name]` | Confirm deletion of the named scene, or the current scene |
| `:Aero scene add` | Choose a registered workspace to include in this scene |
| `:Aero scene remove` | Choose a workspace to remove from this scene |

Names may contain spaces. Scene IDs are stable across renames.
Use `require("aero").scene()` to open the picker from a mapping.

## Workspace membership

A workspace may belong to several scenes. Its worktrees, agents, terminals,
reports, and boards remain the same underlying items in each scene.

`:Aero add [path]` registers a workspace in the current scene. If the repository
is already registered, it also adds its membership to the current scene.
`:Aero scene remove` only removes membership, leaving the repository and its
running sessions intact. A workspace with no memberships remains registered and
can be added again with `:Aero scene add` or found with `:Aero workspaces all`.
The existing workspace delete action still unregisters the workspace globally.

Workspace, worktree, and session navigation defaults to the current scene:

- `:Aero workspaces [all]`
- `:Aero worktrees [all]`
- `:Aero sessions [all]`
- `:Aero pick [current|all]`

Selecting an item from another scene switches to a scene containing it. Shared
workspaces keep the current scene when they already belong to it.

## Conversations and knowledge

General conversations belong to the scene where they were created. Their sidebar
entries and history library are scoped to that scene, including archived history.
Knowledge collections also belong to their creating scene; their spaces, sources,
notes, and research sessions follow the collection. Files stay at their existing
paths, so switching scenes does not interrupt background work or invalidate citations.

Scenes are organizational contexts: a shared repository has the same files and
sessions in every scene containing it.

## Switching and persistence

Switching remembers the last selected worktree or conversation, retains scene-local
sidebar section folds, and returns to that context when you switch back. Running
agents and terminals continue in their existing buffers and tabs.

The attention inbox remains global. When another scene has unread attention events,
the sidebar header shows an **elsewhere** count with a reminder to use `:Aero inbox`.
Opening an event follows its session into a scene containing it.

The companion's **Scene** selector switches the editor's active scene and follows
changes made in Neovim. Home, session lists, and workspace navigation show content
from that scene; workspace scope further narrows those lists. Attention remains
available across scenes, and switching does not stop background agents.
Create, rename, delete, and manage scene membership from Neovim.

Scene definitions, workspace memberships, the active scene, and last selections
are saved alongside Aero's existing state. Existing state automatically belongs to
**Default**, including pre-existing General conversations and knowledge collections.
Versioned, locked [metadata migrations](persistence.md#metadata-migrations) persist
these assignments while keeping all content paths stable.

Deleting a scene preserves its content: General conversations and knowledge
collections are explicitly reassigned to Default, and workspaces with no remaining scene
memberships are assigned to Default. The Default scene may be renamed but cannot
be deleted.

The public `aero.scenes` module exposes `create(name)`, `rename(id, name)`,
`switch(id)`, `delete(id)`, and `membership(root, present, id)`; mutations return
`nil, error` on failure. `scene_switched` events include `scene_id` and
`previous_scene_id`; `scenes_changed` signals scene or membership changes.
