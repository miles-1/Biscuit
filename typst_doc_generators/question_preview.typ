#import "assignment.typ": eval_code, get_all, get_single_selected_question, multiple_choice, true_false, fill_blank, essay

#let preview = json(sys.inputs.at("preview"))
#let global_vars_raw = preview.at("global_vars", default: none)
#let global_vars = if type(global_vars_raw) == str and global_vars_raw.len() > 0 {
  eval_code(global_vars_raw)
} else {
  none
}
#let margin_cm = preview.at("margin", default: 1.5)
#let margin = calc.max(margin_cm, 1.5) * 1cm
#let is_key = preview.at("is_key", default: true)
#let m_q = preview.question
#let s_q = preview.at("selection", default: (:))

#set page(width: 8.5in, height: auto, margin: (x: margin, y: 12pt))
#set text(size: 11pt)

#if is_key {
  align(center, text(14pt, red, strong[KEY]))
  v(6pt, weak: true)
}

#let qs = get_single_selected_question(m_q, s_q, id: none, global_vars: global_vars, is_key: is_key)
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
