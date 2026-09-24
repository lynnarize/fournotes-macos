import Foundation

// Making something new from outside its own tab — the menu bar's New commands
// and the sidebar's "…" menus.
//
// Each one opens what it made. The New Task and New Transaction commands used
// to add a blank row and leave it unopened, where the To-Do tab's blank-task
// cleanup then deleted it the next time the tab appeared.

@MainActor
enum QuickCreate {
    static func note(store: Store, nav: Navigation) {
        let note = store.addNote { $0.title = "" }
        nav.open(ChangeLink(kind: .notes, id: note.id))
    }

    static func task(store: Store, nav: Navigation) {
        let todo = store.addTodo { $0.title = "" }
        nav.open(ChangeLink(kind: .todos, id: todo.id))
    }

    static func transaction(store: Store, nav: Navigation) {
        let tx = store.addTransaction { $0.merchant = "" }
        nav.open(ChangeLink(kind: .transactions, id: tx.id))
    }
}
