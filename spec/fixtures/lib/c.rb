require 'settings'

class C
  @@count = 0
  def self.count
    @@count += 1
  end
end
