#import "assignment.typ": build_var_scope, random_values_box, get_all, get_single_selected_question, multiple_choice, true_false, fill_blank, essay

#let preview = json(sys.inputs.at("preview"))
#let random_values = preview.at("vars", default: none)
#let scope = build_var_scope(preview.at("global_vars", default: none), random_values)
#let is_key = preview.at("is_key", default: true)
#let m_q = preview.question

#set page(width: 8.5in, height: auto, margin: (x: 1.5cm, y: 12pt))
#set text(size: 11pt)

#if is_key {
  align(center, text(14pt, red, strong[KEY]))
  v(6pt, weak: true)
  random_values_box(preview.at("random_vars", default: none), random_values)
}

#let qs = get_single_selected_question(m_q, (:), id: none, scope: scope)
#let q = qs.first()
#assert("type" in q and "body" in q, message: "preview question must have `type` and `body`")
#let unpacked = get_all(q, "type", "body", "points", "correct_answer", "options")
#let q_type = unpacked.type
#let body = unpacked.body
#let points = unpacked.points
#let correct_answer = unpacked.correct_answer
#let options = unpacked.options
#let func = (
  multiple_choice: multiple_choice,
  true_false: true_false,
  fill_blank: fill_blank,
  essay: essay,
).at(q_type)
#let extra_args = if q_type == "essay" { (num_lines: q.at("num_lines", default: none)) } else { (:) }
#let option_args = if type(options) == array { options } else { () }
#let section_q_counter = counter("section_q_counter")
#func(
  body,
  id: none,
  section_q_counter: section_q_counter,
  points: points,
  correct_answer: correct_answer,
  is_key: is_key,
  ..extra_args,
  ..option_args,
)
