#let lpad(body, length, char: "0") = {
  let string = str(body)
  while string.len() < length {string = char + string}
  string
}
#let format_answer(manual_answer, backup:none) = if type(manual_answer) != array {
  if type(manual_answer) == int {manual_answer+1} else {manual_answer}
} else {
  for (ma, a) in manual_answer.zip(backup) {(if ma == none {a} else {ma},)}
}
#let make_horizon_line(img, body) = grid(columns:2, column-gutter:5pt, align:horizon, body, img)
#let get_score(points,max_points) = raw(str(points) + "/" + str(max_points))
#let processed_scans_color = rgb(30,12,155)
#let feedback_arrow_color = red
#let line_stroke = luma(50%).transparentize(50%)
#let background_fill = luma(95%)


#let arrow = text(feedback_arrow_color, strong(math.arrow.t))
#let anchor = box(width:10pt, height:10pt, stroke:processed_scans_color+1.5pt, radius:3pt, place(center+horizon, square(width:6pt, fill:black)))
#let plus = box(width:12pt, height:12pt, for (h,w) in ((15pt,2pt), (2pt,15pt)) {place(center+horizon, rect(height:h, width:w, radius:2pt, fill:processed_scans_color))})
#let diamond = box(rotate(45deg,reflow:true,square(width:10pt, radius:1pt, stroke:processed_scans_color+1.5pt)))

#let get_feedback_documents(
  grading_data, 
  annotated_scan_folder_name,
  include_correct_answers, 
  num_q_table_columns: 3
) = {
  let no_names = 0
  for (assn_id_str, assn_data) in grading_data {
    if assn_id_str == "feedback-templates" {continue}
    // assn id and name
    let assn_id = int(assn_id_str)
    let student_name = assn_data.at("name", default:none)
    if student_name == none {no_names += 1; student_name = "no_name_" + str(no_names)}
    let student_file_name = lower(student_name.replace(", ", "_")) + ".pdf"
    // total points and max points
    let total_points = assn_data.at("total_points", default:none)
    let max_total_points = assn_data.at("max_total_points", default:none)
    // questions
    let questions = assn_data.at("questions", default:none)
    assert(questions != none, message:"missing `questions` in assn data for assn #assn_id_str")
    let num_questions = questions.len()
    let question_chunk_size = calc.ceil(num_questions / num_q_table_columns)
    // feedback content
    let by_page_by_q_content = ()
    let question_notes = ()
    for q in questions {
      let has_feedback = "feedback" in q
      let has_manual_answer = "manual_answer" in q
      while by_page_by_q_content.len() <= q.page {by_page_by_q_content.push(())}
      by_page_by_q_content.at(q.page).push((
        q_height: q.q_height,
        summary: [
          *Question #q.id:* #h(1fr) #if "max_points" in q {get_score(q.points,q.max_points)} else [_ungraded_] #if has_feedback or has_manual_answer {arrow}
        ]
      ))
      if has_feedback or has_manual_answer {
        let notes = if has_manual_answer [_Note: the computer detected that you answered_ #format_answer(q.answer). _After review, the grader determined that this was incorrect, and changed your answer to be marked as_ #format_answer(q.manual_answer, backup:q.answer). #if has_feedback {linebreak()}] + if has_feedback {q.feedback}
        question_notes.push([
          *Question #q.id* (p.#q.page) \ 
          #notes
        ])
      }
    }
    document(student_file_name)[
      #set page(paper:"us-letter", margin:(right:1.5cm,y:1.5cm,left:1.5cm+1em))
      #show heading: h => pad(left:-1.3em, grid(
        columns:2,
        gutter:0.5em,
        move(dy:-1pt, rotate(-30deg, polygon.regular(vertices:3, size:0.8em, fill:black))),
        h
      ))
      #set list(indent:10pt, spacing:1.2em)
      #show title: t => pad(left:-1em, underline(t))

      #place(top+right, dx:0.8cm, dy:-0.8cm, text(luma(50%))[Generated #datetime.today().display("[day] [month repr:short] [year]")])

      #title[Feedback for #student_name.split(",").rev().join(" ")]

      = How to Read This Document

      This document includes your assignment scan, question, and feedback. It #if not include_correct_answers [does *not* include] else [also includes] the correct answers for questions. Below is the scan of your work. It includes a few annotations:

      - #make_horizon_line(anchor)[the black squares around the edge of the page now have a square drawn around them:]
      - #make_horizon_line(plus)[plus-signs are drawn at the top-right corner of each question:]
      - the assignment ID and page number are written in the bottom right.
      - #make_horizon_line(diamond)[each bubble in a multiple choice or true/false question has a diamond drawn around it:]
        - #[#show raw: text.with(processed_scans_color, weight:"bold"); to the left of the bubbles, the computer-detected answer is indicated (`->` for multiple choice, `T`/`F` for true-or-false questions). `NA` means no answer was detected. `?` means the computer wasn't confident about its reading, and it was flagged for review.]
      - to the left of each scanned page, the question ID and score is listed. If the grader left notes for that question, a red arrow is also included: #arrow
      It is possible that the computer scanned your work incorrectly. *If the detected answer is clearly different from your actual answer, please contact the instructor.* In your message, please include if any of the annotations listed above are placed in the wrong location, or if the wrong assignment ID or page number is written.
      
      #if total_points != none and max_total_points != none [ 
        = Total Score: #get_score(total_points, max_total_points)
      ]

      = Scores

      #align(center, grid(
        columns: num_q_table_columns,
        ..for qs in questions.chunks(question_chunk_size) {(
          box(stroke:1.5pt, table(
            columns: 3,
            fill: (_,y) => if y == 0 {luma(80%)},
            inset: (x,y) => if x == 0 and y > 0 {(left:27pt,y:5pt,right:5pt)} else {5pt},
            align: (x,y) => if x == 0 and y > 0 {left} else {center},
            [*Question ID*], [*pg \#*], [*Score*],
            ..for q in qs {(
              [#q.id], [#q.page], if "max_points" in q {get_score(q.points,q.max_points)} else [_ungraded_]
            )}
          )),
        )}
      ))

      #if question_notes.len() > 0 [
        = Grader Notes

        #table(
          columns: 100%,
          stroke: luma(80%),
          inset: 15pt,
          ..for f in question_notes {(f,)}
        )
      ]

      #context for (p, qs) in by_page_by_q_content.enumerate() {
        if p == 0 {continue}
        let img = image(annotated_scan_folder_name + "/assn_" + assn_id_str + "/" + lpad(p,4,char:"0") + ".png")
        let image_to_margin_width_proportion = 3.5
        let margin_to_total_width_proportion = 1 / (image_to_margin_width_proportion + 1)
        let page_width = 612pt
        let (height,) = measure(img, width:page_width*(1-margin_to_total_width_proportion))
        let margin_width = page_width * margin_to_total_width_proportion
        page(
          width: page_width,
          height: height,
          background: {
            place(horizon+right, img)
            place(horizon+left, rect(width:margin_width, height:100%, fill:background_fill))
            for q in qs {
              let args = arguments(left+top, dy: (q.q_height * 1pt / measure(img).height) * height - 2pt)
              place(..args, line(length:100%, stroke:line_stroke))
              place(..args, block(inset:5pt, width:margin_width, q.summary))
            }
          },
          []
        )
      }
    ]
  }
}


#let grading_data_file_name = sys.inputs.at("grading_data", default:none)
#let annotated_scan_folder_name = sys.inputs.at("annotated_scan_folder", default:none)
#let include_correct_answers = sys.inputs.at("include_correct_answers", default:false)
#assert(grading_data_file_name != none and annotated_scan_folder_name != none, message:"missing `grading_data` and `annotated_scan_folder` arguments")
#let grading_data = json(grading_data_file_name)

#get_feedback_documents(grading_data, annotated_scan_folder_name, include_correct_answers)
