module App::Views::@@COLLECTION@@
  class Index < App::ApplicationView
    def initialize(@records : Array(App::@@MODEL@@))
    end

    private def blueprint
      section class: "page-head" do
        div do
          p(class: "eyebrow") { "YOUR COLLECTION" }
          h1 { "@@COLLECTION_LABEL@@" }
        end
        # frappe:only new
        a(class: "button", href: new_@@SINGULAR@@_path) { "New @@LABEL@@" }
        # frappe:end
      end
      if @records.empty?
        section class: "empty-state" do
          h2 { "A fresh start." }
          p { "Add your first @@LABEL@@ to get going." }
        end
      else
        record_table
        p(class: "muted") { "Showing the newest 100 records." }
      end
    end

    private def record_table : Nil
      div class: "table-scroll" do
        table do
          thead do
            tr do
@@TABLE_HEADERS@@
              th(scope: "col") { "Actions" }
            end
          end
          tbody do
            @records.each do |record|
              tr do
@@TABLE_CELLS@@
                td do
                  a(href: @@SINGULAR@@_path(record.id)) { "View" }
                  # frappe:only edit
                  whitespace
                  a(href: edit_@@SINGULAR@@_path(record.id)) { "Edit" }
                  # frappe:end
                end
              end
            end
          end
        end
      end
    end
  end
end
