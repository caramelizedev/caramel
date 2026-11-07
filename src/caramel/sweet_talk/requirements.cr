# `frappe requirements`: the requirement ids a SweetTalk domain declares, each with what
# assures it (ADR 0057). The application answers it; Frappé compiles the application and asks.
module SweetTalk
  REQUIREMENTS_USAGE = "Usage: requirements [ID|--ids]"

  # Prints the requirements for `requirements`, `requirements --ids` or `requirements ID`;
  # returns the exit status: 0, 1 for an ID that is no requirement, 2 for anything else.
  def self.__sweettalk_print_requirements(arguments : Array(String),
                                          output : IO,
                                          errors : IO) : Int32
    declared = declared_requirements
    if arguments.empty?
      output.puts "This application declares no requirements." if declared.empty?
      declared.each { |requirement| __sweettalk_print_requirement(requirement, output) }
      return 0
    end
    word = arguments.size == 1 ? arguments[0] : nil
    if word.nil? || (word != "--ids" && word.starts_with?('-'))
      errors.puts REQUIREMENTS_USAGE
      return 2
    end
    if arguments[0] == "--ids"
      declared.each { |requirement| output.puts requirement.id }
      return 0
    end
    found = declared.find { |requirement| requirement.id == arguments[0] }
    unless found
      listed = declared.empty? ? "none" : declared.map(&.id).join(", ")
      errors.puts "#{arguments[0]} is not a requirement; requirements: #{listed}"
      return 1
    end
    __sweettalk_print_requirement(found, output)
    0
  end

  private def self.__sweettalk_print_requirement(requirement : Requirement, output : IO) : Nil
    output.puts requirement.id
    if requirement.assured_by.empty?
      output.puts "  nothing assures it"
      return
    end
    requirement.assured_by.each do |assurance|
      output.puts "  #{assurance.kind} #{assurance.owner}: #{assurance.text}"
    end
  end
end

Caramel::Crema.command("requirements", "requirements [ID|--ids]") do |arguments|
  SweetTalk.__sweettalk_print_requirements(arguments, STDOUT, STDERR)
end
