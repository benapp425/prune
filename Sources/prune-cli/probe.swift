import Foundation
import PruneCore
func probe(_ path: String) {
    let l = BulkLister()
    l.list(path) { e in print(e.name, e.kind, "logical", e.logical, "alloc", e.allocated, "private", e.privateSize, "links", e.linkCount, "ext", e.extFlags, "reclaim", e.reclaimable, String(e.flags, radix: 16)) }
}
