module Caramel::I18n
  # A catalog key, and a placeholder name: a lowercase identifier.
  KEY = /\A[a-z][a-z0-9_]*\z/

  # Keys a catalog may not use. Each message becomes a method, so Crystal's
  # keywords and the methods every value has are refused, and so is `locale`,
  # which every message group holds. `frappe make resource` refuses fields
  # with these names in a localized application.
  RESERVED_KEYS = %w[
    abstract alias annotation as asm begin break case class def do else elsif
    end ensure enum extend false for fun if in include instance_sizeof is_a?
    lib macro module next nil nil? of offsetof out pointerof private
    protected require rescue responds_to? return select self sizeof struct
    super then true type typeof uninitialized union unless until verbatim
    when while with yield
    dup clone hash inspect to_s itself tap try not_nil! object_id same?
    locale initialize
  ]
end
