require "../../../src/caramel/corretto"

values = ["Tea", "Coffee"]
"<ul><li>Tea</li><li>Coffee</li></ul>".should have_html {
  ul { values.each { |value| li { value } } }
}
"<select><option selected>Tea</option></select>".should have_html {
  select_tag { option(selected: true) { values.first } }
}
"<tea-cup>Tea</tea-cup>".should have_html { element("tea-cup") { values.first } }
