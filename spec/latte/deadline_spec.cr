require "spec"
require "../../src/latte/deadline"

describe Caramel::Latte::OperationDeadline do
  it "shares an aggregate budget across steps and permits bounded cleanup afterward" do
    Caramel::Latte::OperationDeadline.run(10.milliseconds) do
      Caramel::Latte::OperationDeadline.limit(1.second).should be <= 10.milliseconds
      sleep 15.milliseconds
      expect_raises(Caramel::Latte::DeadlineExceeded) { Caramel::Latte::OperationDeadline.check! }
      Caramel::Latte::OperationDeadline.without do
        Caramel::Latte::OperationDeadline.limit(1.second).should eq(1.second)
      end
      expect_raises(Caramel::Latte::DeadlineExceeded) { Caramel::Latte::OperationDeadline.check! }
    end
    Caramel::Latte::OperationDeadline.limit(1.second).should eq(1.second)
  end
end
