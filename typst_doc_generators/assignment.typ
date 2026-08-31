#import "@preview/tiaoma:0.3.0": data-matrix


// misc
#let BUBBLE = [#circle(radius:4pt)<bubble>]
#let BUBBLE_FILLED = circle(radius:4pt, fill:black)
#let BLANK = box(inset: (bottom: -2pt), line(length: 30%))
#let TRAINING_DATA_NAME_BOXES = align(center, block(stroke:black, inset:20pt, fill:tiling(size:(10pt,10pt), {
  place(line(stroke:luma(50%),start:(0%,0%), end:(100%,100%))); place(line(stroke:luma(50%),start:(0%,100%), end:(100%,0%)))}), table(gutter:20pt, inset:2pt, columns:(200pt,)*2, rows:(40pt,)*6, fill:white, ..for _ in range(12) {(for pos in (top+left, top+right, bottom+left, bottom+right) {place(pos, [#box()<name_box_corner>])},)})))
#let anchor = [#square(width: 5pt, fill:black)<anchor>]
#let q_height = [#box()<q_height>]
#let get_all(dict, ..keys, default:none) = for k in keys.pos() {((k, dict.at(k, default:default)),)}.to-dict()
#let apply(val_or_array, func) = if type(val_or_array) == array {val_or_array.map(func)} else {func(val_or_array)}
#let linspace(start, end, count) = range(count).map(i => {start + i * (end - start) / (count - 1)})
#let lpad(body, length, char: "0") = {let string = str(body); while string.len() < length {string = char + string}; return string}
#let eval_mkup(string, global_vars:none, vars:none, secondary_vars:none, type:none) = {
  let scope = if std.type(global_vars) == dictionary {global_vars} else {(:)}
  scope += vars + secondary_vars
  if type == "fill_blank" {scope.insert("BLANK", BLANK)}
  if type == "essay" {scope.insert("TRAINING_DATA_NAME_BOXES", TRAINING_DATA_NAME_BOXES)}
  eval(string, mode:"markup", scope:scope)
}
#let eval_code(string, global_vars:none, vars:none, secondary_vars:none) = {
  let scope = if type(global_vars) == dictionary {global_vars} else {(:)}
  scope += vars + secondary_vars
  eval(string, scope:scope)
}
#let to-string(it) = {
  if type(it) == str {
    it
  } else if type(it) != content {
    str(it)
  } else if it.has("text") {
    it.text
  } else if it.has("children") {
    it.children.map(to-string).join()
  } else if it.has("body") {
    to-string(it.body)
  } else if it == [ ] {
    " "
  } else {
    "[UNRESOLVED TEXT]"
  }
}

// data matrix
#let b64_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
#let to_base64(b_obj) = {
  let b = array(b_obj)
  let res = ""
  for i in range(0, b.len(), step: 3) {
    let n = (b.at(i) * 65536) + (if i + 1 < b.len() {b.at(i + 1) * 256} else {0}) + (if i + 2 < b.len() {b.at(i + 2)} else {0})
    res += b64_alphabet.at(calc.floor(n / 262144))
    res += b64_alphabet.at(calc.rem(calc.floor(n / 4096), 64))
    res += if i + 1 < b.len() {b64_alphabet.at(calc.rem(calc.floor(n / 64), 64))}
    res += if i + 2 < b.len() {b64_alphabet.at(calc.rem(n, 64))}
  }
  return res
}
#let pack_assn_data(data) = {
  let b = (
    calc.floor(data.assn_id / 256),
    calc.rem(data.assn_id, 256),
    data.page
  )
  return bytes(b)
}
#let assn_page_data_matrix(data, scale:1.5) = {
  let raw_bytes = pack_assn_data(data)
  let payload = to_base64(raw_bytes)
  return data-matrix(payload, options:(scale:scale))
}

// question types
#let key_answer(a) = underline(text(red, a))
#let get_grid_args(..args, is_single_correct_answer:true) = {
  let options = args.pos()
  assert(options.len() >= 1, message:"number of options must be at least 1")
  let correct_answer = args.named().at("correct_answer", default:none)
  if correct_answer != none {
    if type(correct_answer) != array {
      correct_answer = (correct_answer,)
      assert(is_single_correct_answer, message:"correct answer(s) must be given as an array")
    } else {
      assert(not is_single_correct_answer, message:"only an integer correct_answer can be used here")
    }
    for i in correct_answer {
      assert(type(i) == int, message:"`correct_answer` must be integer(s), got " + str(i))
      assert(i >= 0 and i < options.len(), message:"expected `correct_answer` number(s) to be nonnegative and less than " + str(options.len()) + ", got " + str(i))
    }
  }
  let info = (: ..args.named(), correct_answer:correct_answer)
  return (options:options, info:info)
}
#let question(body, id:none, points:none, correct_answer:none, section_q_counter:none, is_key:false, par_leading:0.65em) = block(width:100%, breakable:false, inset:(bottom:5mm), {
  assert(section_q_counter != none, message:"`section_q_counter` must be provided")
  section_q_counter.step()
  if is_key and id != none {strong[#h(2mm) {question id: #id} \ #v(2mm, weak:true) ]}
  if not is_key {place(top+right, q_height)}
  grid(
    columns: (20pt, 100%-40pt),
    column-gutter: 10pt,
    align: (x,_) => if x == 0 {right} else {left},
    context strong(section_q_counter.display("1.")),
    {
      set par(leading:par_leading)
      if points != none {emph[[#points pt#if points != 1 [s]#if correct_answer==none and points > 0 [ for completion]] ]}
      body
    }
  )
})
#let grid_question(body, ..grid_args, header_cells:none, id:none, points:none, correct_answer:none, section_q_counter:none, is_key:false) = {
  let named_grid_args = grid_args.named()
  assert("columns" in named_grid_args, message:"`columns` is required argument")
  let num_columns = named_grid_args.columns
  let grid_cells = if is_key and correct_answer != none {
    let grid_cell_chunks = grid_args.pos().chunks(num_columns)
    for indx in range(0, grid_cell_chunks.len()) {
      let is_false_answer = indx not in correct_answer
      if is_false_answer and num_columns == 2 {continue}
      grid_cell_chunks.at(indx).at(int(indx not in correct_answer)) = BUBBLE_FILLED
    }
    grid_cell_chunks.flatten()
  } else {
    grid_args.pos()
  }
  question(
    id: id,
    points: points,
    correct_answer: correct_answer,
    is_key: is_key,
    section_q_counter: section_q_counter,
    {
      body
      set par(leading:4pt)
      grid(
        row-gutter: 10pt,
        column-gutter: 5pt,
        align: (x,y) => top + if x < num_columns - 1 {center} else {left},
        ..named_grid_args,
        ..header_cells,
        ..grid_cells
      )
    }
  )
}
#let multiple_choice(body, ..args) = {
  let (options, info) = get_grid_args(..args, is_single_correct_answer:true)
  grid_question(
    body + [ Choose *one* option.],
    columns: 2,
    ..for o in options {(BUBBLE, o)},
    ..info,
  )
}
#let true_false(body, ..args) = {
  let (options, info) = get_grid_args(..args, is_single_correct_answer:false)
  grid_question(
    body + [ For *each* option, choose true or false.],
    columns: 3,
    header_cells: (strong[T], strong[F], none),
    row-gutter: (3pt, 10pt),
    ..for o in options {(BUBBLE, BUBBLE, o)},
    ..info,
  )
}
#let fill_blank(body, ..args) = question(
  ..args,
  par_leading: 1.2em,
  {
    let is_key = args.named().at("is_key", default:false)
    if is_key {
      let correct_answer = args.named().at("correct_answer", default:none)
      let blank_count = counter("BLANK")
      blank_count.update(0)
      show regex("\#BLANK"): it => {
        blank_count.step()
        if correct_answer == none {
          BLANK
        } else if type(correct_answer) != array {
          key_answer(correct_answer)
        } else {
          context key_answer(correct_answer.at(blank_count.get().first() - 1))
        }
      }
    }
    body
  },
)
#let essay(body, num_lines:none, ..args) = question(
  ..args,
  {
    let is_key = args.named().at("is_key", default:false)
    let correct_answer = args.named().at("correct_answer", default:none)
    body
    v(5pt)
    if is_key and correct_answer != none {key_answer(correct_answer)} else {for i in range(0,if num_lines == none {2} else {num_lines}) {v(7pt);line(length:100%)}}
  },
)

// traversing json
#let get_single_selected_question(m_q, s_q, id:"", global_vars:none, is_key:false) = {
  let (option_permutation, vars, type) = get_all(s_q, "option_permutation", "vars", "type")
  let (secondary_vars, type, options, correct_answer) = get_all(m_q, "secondary_vars", "type", "options", "correct_answer")
  if std.type(vars) == dictionary {
    m_q.vars = vars
    if std.type(secondary_vars) == dictionary {
      let evald_secondary_vars = (:)
      for (k,v) in secondary_vars.pairs() {
        evald_secondary_vars.insert(k, eval_code(v, global_vars:global_vars, vars:vars, secondary_vars:evald_secondary_vars))
      }
      secondary_vars = evald_secondary_vars
      m_q.secondary_vars = secondary_vars
    }
  }
  if not is_key {
    m_q.body = eval_mkup(m_q.body, global_vars:global_vars, vars:vars, secondary_vars:secondary_vars, type:type)
  }
  if options != none {
    if option_permutation != none {
      options = option_permutation.map(i=>options.at(i))
    }
    if not is_key {
      m_q.options = options.map(eval_mkup.with(global_vars:global_vars, vars:vars, secondary_vars:secondary_vars))
    }
  }
  if correct_answer != none and not is_key and type in ("essay", "fill_blank") {
    m_q.correct_answer = apply(correct_answer, eval_mkup.with(global_vars:global_vars, vars:vars, secondary_vars:secondary_vars))
  }
  m_q.insert("id", id)
  return (m_q,)
}
#let get_selected_questions(m_dict, s_dict, is_top_level:true, global_vars:none, is_key:false, id:"") = {
  let m_qs = m_dict.at("questions", default:none)
  let s_qs = s_dict.at("questions", default:none)
  let has_sections = is_top_level and "section_title" in m_qs.first()
  if has_sections {
    return for (indx, (m_q, s_q)) in m_qs.zip(s_qs).enumerate() {(
      eval_mkup(global_vars:global_vars, m_q.section_title),
      ..get_selected_questions(m_q, s_q, id:str(indx), global_vars:global_vars, is_key:is_key)
    )}
  }
  if id != "" {id = id + "-"}
  return for s_q in s_qs {
    if type(s_q) == int {s_q = (indx: s_q)}
    let (indx,) = s_q
    let m_q = m_qs.at(indx)
    if "questions" not in s_q {
      get_single_selected_question(m_q, s_q, id:id+str(indx), global_vars:global_vars, is_key:is_key)
    } else {
      get_selected_questions(m_q, s_q, id:id+str(indx), global_vars:global_vars, is_key:is_key)
    }
  }
}

#let assn_versions(master, selection, single_doc_export, will_print_double_sided) = {
  // unpack from master and selection
  let make_doc = if single_doc_export {(title, body) => {body}} else {document}
  let (title, intro_content, questions, margin, section_numbering, global_vars) = get_all(master, "title", "intro_content", "questions", "margin", "section_numbering", "global_vars")
  margin = if margin != none {calc.max(margin,1.5)*1cm} else {1.5cm}
  let versions = selection.at("versions", default:none)
  if type(global_vars) == str {global_vars = eval_code(global_vars)}
  // doc set up
  set page(paper:"us-letter", margin:margin, numbering:"(1)")
  let section_q_counter = counter("section_q_counter")
  let total_q_counter = counter("total_q_counter")
  let assn_id_state = state("assn_id", -1)
  let var_answers_state = state("var_answers", (:))
  set heading(numbering:section_numbering)
  show heading.where(level: 1): it => {section_q_counter.update(0); it}
  // make each version
  for v in versions {
    let is_key = v.at("is_key", default:false)
    let assn_id = v.at("assn_id", default:none)
    if assn_id != none {assn_id_state.update(assn_id)}
    make_doc(
      "assn_" + if assn_id != none {lpad(assn_id)} else {"_key"} + ".pdf",
      {
        total_q_counter.update(0)
        section_q_counter.update(0)
        if single_doc_export {
          counter(page).update(1)
          counter(heading).update(0)
        }
        set page(
          background: context if is_key {
            place(center+top, dy:15pt, text(30pt, red, strong[KEY]))
          } else {
            let p_indx = counter(page).get().first()
            place(left+bottom, dx: 15pt, dy: -15pt, {
              assn_page_data_matrix((assn_id:assn_id, page:p_indx))
              [#std.v(3pt,weak:true) #h(8pt) #assn_id]
            })
            for y in linspace(15, 772, 5) {
              place(left+top, dx:15pt, dy:y*1pt, anchor)
              place(right+top, dx:-15pt, dy:y*1pt, anchor)
            }
            for x in linspace(15, 592, 4) {
              if x < 20 or x > 580 {continue}
              place(top+left, dx:x*1pt, dy:15pt, anchor)
              place(bottom+left, dx:x*1pt, dy:-15pt, anchor)
            }
          }
        )
        pad(right:270pt, std.title(eval_mkup(global_vars:global_vars, title)))
        if intro_content != none {eval_mkup(global_vars:global_vars, intro_content)}
        place(top+right, dy:-30pt, dx:10pt, [
          #box(text(16pt, baseline:-15pt, strong[Name: ]))
          #box(width:200pt, height:55pt, {
            for pos in (top+left, top+right, bottom+left, bottom+right) {
              place(pos, [#box()<name_field_corner>])
            }
            place(bottom+left, dy:-13pt, line(length: 100%))
          })
        ])
        let qs = get_selected_questions(master, v, global_vars:global_vars, is_key:is_key)
        for q in qs {
          if type(q) != dictionary {heading(q);std.v(5mm,weak:true);continue}
          total_q_counter.step()
          assert("type" in q and "body" in q, message:"all questions must have the `type` and `body` keys specified")
          let (type, body, id, points, correct_answer, options, vars, secondary_vars) = get_all(q, "type", "body", "id", "points", "correct_answer", "options", "vars", "secondary_vars")
          let func = (
            multiple_choice: multiple_choice,
            true_false: true_false,
            fill_blank: fill_blank,
            essay: essay
          ).at(type)
          let extra_args = if type == "essay" {(num_lines: q.at("num_lines", default:none))} else {(:)}
          if not is_key and type in ("essay", "fill_blank") and vars != none {
            context {
              let current_q_num = str(total_q_counter.get().first() - 1)
              var_answers_state.update(d => {
                if str(assn_id) not in d {d.insert(str(assn_id), (:))}
                d.at(str(assn_id)).insert(current_q_num, apply(correct_answer, to-string))
                return d
              })
            }
          }
          func(
            body,
            id: id,
            section_q_counter: section_q_counter,
            points: points,
            correct_answer: correct_answer,
            is_key: is_key,
            ..extra_args,
            ..options
          )
        }
        if will_print_double_sided {
          if single_doc_export {pagebreak()}
          let end_label = label("end-of-doc" + str(if assn_id != none {assn_id} else {"_key"}))
          [#box()#end_label]
          context {
            let final_page = counter(page).at(end_label).first()
            if calc.odd(final_page) {pagebreak()}
          }
        }
      }
    )
  }
  context if single_doc_export {
    let page_elems = (:)
    let el_types_and_shift = (
      "anchor": 2.5pt, // width of anchor is 5pt
      "bubble": 4pt, // radius of bubble is 4pt
      "q_height": 0pt, 
      "name_box_corner": 0pt,
      "name_field_corner": 0pt,
    )
    let query_results = for el_type in el_types_and_shift.keys() {query(label(el_type)).map(i=>(el_type, i))}
    for (el_type, el) in query_results {
      let el_loc = el.location()
      let assn_id_int = assn_id_state.at(el_loc)
      if assn_id_int < 0 {continue}
      let assn_id = str(assn_id_int)
      let p_indx = str(counter(page).at(el_loc).first())
      if assn_id not in page_elems {page_elems.insert(assn_id, (:))}
      if p_indx not in page_elems.at(assn_id) {page_elems.at(assn_id).insert(p_indx, (:))}
      if el_type + "s" not in page_elems.at(assn_id).at(p_indx) {page_elems.at(assn_id).at(p_indx).insert(el_type + "s", ())}
      let shift = el_types_and_shift.at(el_type)
      let (x,y) = el_loc.position()
      page_elems.at(assn_id).at(p_indx).at(el_type + "s").push((x+shift,y+shift))
    }
    [#metadata(page_elems)<page_elems>]
    [#metadata(var_answers_state.final())<var_answers>]
  } 
}

#let master_file_name = sys.inputs.at("master", default:none)
#let selection_file_name = sys.inputs.at("selection", default:none)
#let single_doc_export = sys.inputs.at("single_doc_export", default:"false") == "true"
#let will_print_double_sided = sys.inputs.at("will_print_double_sided", default:"true") == "true"
#assert(master_file_name != none and selection_file_name != none, message:"missing `master` or `selection` argument")

#let master = json(master_file_name)
#let selection = json(selection_file_name)

#assn_versions(master, selection, single_doc_export, will_print_double_sided)


