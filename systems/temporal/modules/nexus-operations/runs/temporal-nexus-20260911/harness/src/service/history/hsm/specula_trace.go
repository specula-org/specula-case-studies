package hsm

import "go.temporal.io/server/common/speculatrace"

func (n *Node) SpeculaEmit(event string, args any) {
 if !speculatrace.Enabled() { return }
 if ms, ok := n.backend.(interface{ SpeculaEmit(string, any) }); ok {
  ms.SpeculaEmit(event, map[string]any{"args": args, "path": n.Path(), "node": speculatrace.Proto(n.persistence), "deleted": n.cache.deleted})
 }
}

func speculaTasks(tasks []Task) []any {
 result := make([]any, 0, len(tasks))
 for _, task := range tasks {
  result = append(result, map[string]any{"type": task.Type(), "deadline": task.Deadline(), "destination": task.Destination(), "data": task})
 }
 return result
}
