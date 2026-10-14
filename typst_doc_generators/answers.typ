#import "assignment.typ": build_var_scope, get_selected_questions

// Input names differ from assignment.typ's `master`/`selection`, since both files are compiled as
// one source and those inputs would also render the whole assignment.
#let master = json(sys.inputs.at("answer_master"))
#let selection = json(sys.inputs.at("answer_selection"))
// [{assn_id, ids}]: one page per id, in this order, so page N is the Nth answer the caller asked for.
#let jobs = json(sys.inputs.at("answer_jobs"))

#set page(width: 4.5in, height: auto, margin: 6pt)
#set text(size: 11pt)

#{
  let versions = (:)
  for v in selection.versions {
    if v.at("is_key", default: false) { continue }
    versions.insert(str(v.assn_id), v)
  }
  let is_first_page = true
  for job in jobs {
    let v = versions.at(str(job.assn_id))
    let scope = build_var_scope(master.at("global_vars", default: none), v.at("vars", default: none))
    let by_id = (:)
    for q in get_selected_questions(master, v, scope: scope) {
      if type(q) == dictionary and "id" in q { by_id.insert(q.id, q) }
    }
    for id in job.ids {
      if not is_first_page { pagebreak() }
      is_first_page = false
      let answer = by_id.at(id).correct_answer
      if type(answer) == array { enum(..answer) } else { answer }
    }
  }
}
