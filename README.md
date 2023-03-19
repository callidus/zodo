# zodo

A todo.txt TUI coded in Zig. This is an effort to learn the Zig programming language by creating a simple (but not too simple) program that could also be somewhat useful. I am probably doing a bunch of stuff wrong or "not the Zig way" so keep that in mind if you read over the code during your own Zig journey.

## Controls

| Key      | Function         |
| :---     | :---             |
| left, h  | Complete task    |
| right, l | un-complete task |
| up, j    | Move up          |
| down, k  | Move down        |
| q        | quit             |
| p        | lower-case p, filter task list by the selected tasks projects |
| P        | upper-case P, remove any project filter |
| c        | lower-case c, filter task list by the selected tasks contexts |
| C        | upper-case C, remove any context filter |

Applying a context and project filter will hide all tasks that do not have at least one selected context and at least one selecte dproject.
