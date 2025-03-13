require "active_record"
require "logger"
require "stackprof"
require "benchmark/ips"

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveRecord::Schema.define do
  create_table :posts, force: true do |t|
  end
  create_table :comments, force: true do |t|
    t.belongs_to :post
    t.string :title
    t.text :body
    t.integer :likes
    t.datetime :posted_at
  end
end

class Post < ActiveRecord::Base
  has_many :comments
end

class Comment < ActiveRecord::Base
  belongs_to :post
end

200.times do
  Comment.create!
end

Comment.first

data0 = Comment._query_by_sql(Comment.connection, "SELECT * FROM comments")
data0 = Ractor.make_shareable(data0)
p data0.column_types
20.times do

  10.times.map do
    data = Ractor.new(data0) do |data0|
      Ractor.make_shareable(ActiveRecord::Result.new(data0.columns, data0.rows, data0.column_types))
    end
    Ractor.new(data) do |data|
      data = data.take
      10.times.map do
        Comment._load_from_sql(data)
      end
    end
  end.map(&:take)
end
