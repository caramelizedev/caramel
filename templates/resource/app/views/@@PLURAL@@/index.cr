module App::Views::@@COLLECTION@@
  class Index < App::ApplicationView
    def initialize(@records : Array(App::@@MODEL@@))
    end

    private def blueprint
      section class: "page-head" do
        div do
          # frappe:only locales
          p(class: "eyebrow") { t.common.your_collection }
          # frappe:else
          p(class: "eyebrow") { "YOUR COLLECTION" }
          # frappe:end
          # frappe:only locales
          h1 { t.@@PLURAL@@.collection }
          # frappe:else
          h1 { "@@COLLECTION_LABEL@@" }
          # frappe:end
        end
        # frappe:only new
        # frappe:only locales
        a(class: "button", href: new_@@SINGULAR@@_path) { t.@@PLURAL@@.new_record }
        # frappe:else
        a(class: "button", href: new_@@SINGULAR@@_path) { "New @@LABEL@@" }
        # frappe:end
        # frappe:end
      end
      if @records.empty?
        section class: "empty-state" do
          # frappe:only locales
          h2 { t.common.fresh_start }
          # frappe:else
          h2 { "A fresh start." }
          # frappe:end
          # frappe:only locales
          p { t.@@PLURAL@@.first_record }
          # frappe:else
          p { "Add your first @@LABEL@@ to get going." }
          # frappe:end
        end
      else
        record_table
        # frappe:only locales
        p(class: "muted") { t.common.newest }
        # frappe:else
        p(class: "muted") { "Showing the newest 100 records." }
        # frappe:end
      end
    end

    private def record_table : Nil
      div class: "table-scroll" do
        table do
          thead do
            tr do
@@TABLE_HEADERS@@
              # frappe:only locales
              th(scope: "col") { t.common.actions }
              # frappe:else
              th(scope: "col") { "Actions" }
              # frappe:end
            end
          end
          tbody do
            @records.each do |record|
              tr do
@@TABLE_CELLS@@
                td do
                  # frappe:only locales
                  a(href: @@SINGULAR@@_path(record.id)) { t.common.view }
                  # frappe:else
                  a(href: @@SINGULAR@@_path(record.id)) { "View" }
                  # frappe:end
                  # frappe:only edit
                  whitespace
                  # frappe:only locales
                  a(href: edit_@@SINGULAR@@_path(record.id)) { t.common.edit }
                  # frappe:else
                  a(href: edit_@@SINGULAR@@_path(record.id)) { "Edit" }
                  # frappe:end
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
