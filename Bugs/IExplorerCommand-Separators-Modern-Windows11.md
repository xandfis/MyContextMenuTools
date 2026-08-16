# IExplorerCommand separators render in the legacy context menu but not the Windows 11 modern context menu

## Summary

`IExplorerCommand` items that return `ECF_ISSEPARATOR` render as divider lines in the legacy File Explorer context menu, but do not render as divider lines in the Windows 11 modern context menu.

## Impact

Shell extensions implemented with `IExplorerCommand` cannot visually group commands in the Windows 11 modern context menu, even though the same command objects work in the legacy context menu. This makes modern menu layouts less readable and forces extensions either to omit grouping or use non-native workaround items.

## Environment

- OS: Windows 11
- Surface: File Explorer context menu
- Extension API: packaged `IExplorerCommand` COM server registered through `desktop4:FileExplorerContextMenus`
- Repository used for repro: `MyContextMenuTools`

## Repro steps

1. Implement an `IExplorerCommand` item whose `GetFlags` returns `ECF_ISSEPARATOR`.
2. Return that item from `IEnumExplorerCommand::Next` between two normal command items.
3. Register the shell extension for File Explorer context menus.
4. Open the Windows 11 modern context menu for a file or folder.
5. Open the legacy context menu for the same file or folder, for example via "Show more options".

## Expected result

The separator item renders as a divider line in both the Windows 11 modern context menu and the legacy context menu.

## Actual result

The separator item renders correctly as a divider line in the legacy context menu, but does not render as a divider line in the Windows 11 modern context menu.

## Notes

The separator item is produced through the documented `IExplorerCommand::GetFlags` mechanism rather than through registry verb layout. The same implementation path also returns normal commands and subcommands successfully in the Windows 11 modern context menu, so the issue appears specific to `ECF_ISSEPARATOR` handling in the modern menu renderer.
