module Caramel::I18n
  # A CLDR plural category.
  enum Plural
    Zero
    One
    Two
    Few
    Many
    Other
  end

  # CLDR 47's cardinal plural rules for whole numbers (the operand v = 0),
  # one method per family of languages that share them. A count's sign does
  # not change its category.
  module Rules
    extend self

    def other(n : Int) : Plural
      Plural::Other
    end

    def one(n : Int) : Plural
      n.abs_unsigned == 1 ? Plural::One : Plural::Other
    end

    def zero_one(n : Int) : Plural
      n.abs_unsigned <= 1 ? Plural::One : Plural::Other
    end

    def one_ending(n : Int) : Plural
      n = n.abs_unsigned
      n % 10 == 1 && n % 100 != 11 ? Plural::One : Plural::Other
    end

    def romance(n : Int) : Plural
      n = n.abs_unsigned
      return Plural::One if n == 1
      millions?(n) ? Plural::Many : Plural::Other
    end

    def french(n : Int) : Plural
      n = n.abs_unsigned
      return Plural::One if n <= 1
      millions?(n) ? Plural::Many : Plural::Other
    end

    def east_slavic(n : Int) : Plural
      n = n.abs_unsigned
      return Plural::One if n % 10 == 1 && n % 100 != 11
      few_ending?(n) ? Plural::Few : Plural::Many
    end

    def polish(n : Int) : Plural
      n = n.abs_unsigned
      return Plural::One if n == 1
      few_ending?(n) ? Plural::Few : Plural::Many
    end

    def czech(n : Int) : Plural
      case n.abs_unsigned
      when 1    then Plural::One
      when 2..4 then Plural::Few
      else           Plural::Other
      end
    end

    def south_slavic(n : Int) : Plural
      n = n.abs_unsigned
      return Plural::One if n % 10 == 1 && n % 100 != 11
      few_ending?(n) ? Plural::Few : Plural::Other
    end

    def slovenian(n : Int) : Plural
      case n.abs_unsigned % 100
      when 1    then Plural::One
      when 2    then Plural::Two
      when 3, 4 then Plural::Few
      else           Plural::Other
      end
    end

    def lithuanian(n : Int) : Plural
      n = n.abs_unsigned
      return Plural::Other if teens?(n) || n % 10 == 0
      n % 10 == 1 ? Plural::One : Plural::Few
    end

    def latvian(n : Int) : Plural
      n = n.abs_unsigned
      return Plural::Zero if teens?(n) || n % 10 == 0
      n % 10 == 1 ? Plural::One : Plural::Other
    end

    def romanian(n : Int) : Plural
      n = n.abs_unsigned
      return Plural::One if n == 1
      n == 0 || (1..19).includes?(n % 100) ? Plural::Few : Plural::Other
    end

    def hebrew(n : Int) : Plural
      case n.abs_unsigned
      when 1 then Plural::One
      when 2 then Plural::Two
      else        Plural::Other
      end
    end

    def arabic(n : Int) : Plural
      n = n.abs_unsigned
      return Plural::Zero if n == 0
      return Plural::One if n == 1
      return Plural::Two if n == 2
      case n % 100
      when 3..10  then Plural::Few
      when 11..99 then Plural::Many
      else             Plural::Other
      end
    end

    def irish(n : Int) : Plural
      case n.abs_unsigned
      when 1     then Plural::One
      when 2     then Plural::Two
      when 3..6  then Plural::Few
      when 7..10 then Plural::Many
      else            Plural::Other
      end
    end

    def welsh(n : Int) : Plural
      case n.abs_unsigned
      when 0 then Plural::Zero
      when 1 then Plural::One
      when 2 then Plural::Two
      when 3 then Plural::Few
      when 6 then Plural::Many
      else        Plural::Other
      end
    end

    # Ends in 2, 3 or 4, but not in 12, 13 or 14.
    private def few_ending?(n : Int) : Bool
      (2..4).includes?(n % 10) && !(12..14).includes?(n % 100)
    end

    # Ends in 11 to 19.
    private def teens?(n : Int) : Bool
      (11..19).includes?(n % 100)
    end

    private def millions?(n : Int) : Bool
      n != 0 && n % 1_000_000 == 0
    end
  end

  # Each family's categories: `all` that its languages use, and `integer`,
  # those a whole number can fall in. A plural message defines every
  # integer category and may define any other of `all`.
  FAMILIES = {
    "other"        => {all: %w[other], integer: %w[other]},
    "one"          => {all: %w[one other], integer: %w[one other]},
    "zero_one"     => {all: %w[one other], integer: %w[one other]},
    "one_ending"   => {all: %w[one other], integer: %w[one other]},
    "romance"      => {all: %w[one many other], integer: %w[one many other]},
    "french"       => {all: %w[one many other], integer: %w[one many other]},
    "east_slavic"  => {all: %w[one few many other], integer: %w[one few many]},
    "polish"       => {all: %w[one few many other], integer: %w[one few many]},
    "czech"        => {all: %w[one few many other], integer: %w[one few other]},
    "south_slavic" => {all: %w[one few other], integer: %w[one few other]},
    "slovenian"    => {all: %w[one two few other], integer: %w[one two few other]},
    "lithuanian"   => {all: %w[one few many other], integer: %w[one few other]},
    "latvian"      => {all: %w[zero one other], integer: %w[zero one other]},
    "romanian"     => {all: %w[one few other], integer: %w[one few other]},
    "hebrew"       => {all: %w[one two other], integer: %w[one two other]},
    "arabic"       => {
      all:     %w[zero one two few many other],
      integer: %w[zero one two few many other],
    },
    "irish" => {all: %w[one two few many other], integer: %w[one two few many other]},
    "welsh" => {
      all:     %w[zero one two few many other],
      integer: %w[zero one two few many other],
    },
  }

  # Each language's family, by tag. A full tag such as pt-PT is looked up
  # before its language subtag.
  LANGUAGES = {
    "ja" => "other", "zh" => "other", "ko" => "other", "th" => "other", "vi" => "other",
    "id" => "other", "ms" => "other", "my" => "other", "km" => "other", "lo" => "other",
    "yue" => "other",
    "en" => "one", "de" => "one", "nl" => "one", "sv" => "one", "nb" => "one", "nn" => "one",
    "no" => "one", "da" => "one", "fi" => "one", "et" => "one", "el" => "one", "hu" => "one",
    "tr" => "one", "bg" => "one", "sq" => "one", "az" => "one", "ka" => "one", "kk" => "one",
    "ky" => "one", "uz" => "one", "mn" => "one", "sw" => "one", "eu" => "one", "gl" => "one",
    "af" => "one", "ur" => "one", "ta" => "one", "te" => "one", "ml" => "one", "mr" => "one",
    "ne" => "one", "so" => "one", "fy" => "one", "lb" => "one", "ast" => "one", "fo" => "one",
    "hi" => "zero_one", "bn" => "zero_one", "gu" => "zero_one", "kn" => "zero_one",
    "fa" => "zero_one", "am" => "zero_one", "zu" => "zero_one", "as" => "zero_one",
    "is" => "one_ending", "mk" => "one_ending",
    "es" => "romance", "it" => "romance", "ca" => "romance", "pt-PT" => "romance",
    "fr" => "french", "pt" => "french",
    "ru" => "east_slavic", "uk" => "east_slavic", "be" => "east_slavic",
    "pl" => "polish",
    "cs" => "czech", "sk" => "czech",
    "hr" => "south_slavic", "sr" => "south_slavic", "bs" => "south_slavic",
    "sl" => "slovenian",
    "lt" => "lithuanian",
    "lv" => "latvian",
    "ro" => "romanian",
    "he" => "hebrew",
    "ar" => "arabic",
    "ga" => "irish",
    "cy" => "welsh",
  }

  # Languages written right to left, by language subtag.
  RIGHT_TO_LEFT = %w[ar he fa ur ps sd ug yi dv ckb]
end
