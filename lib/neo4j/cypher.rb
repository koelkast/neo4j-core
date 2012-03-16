module Neo4j
  class Cypher
    class Expression
      attr_reader :expressions, :clause
      attr_accessor :separator

      def initialize(expressions, clause)
        @clause = clause
        @expressions = expressions
        insert_last(clause)
        @separator = ","
      end

      def insert_last(clause)
        i = @expressions.reverse.index { |e| e.clause == clause }
        if i.nil?
          @expressions << self
        else
          pos = @expressions.size - i
          @expressions.insert(pos, self)
        end
      end

      def prefixes
        {:start => "START", :where => " WHERE", :match => " MATCH", :return => " RETURN"}
      end

      def prefix
        prefixes[clause]
      end
    end

    class Property
      attr_reader :expressions, :var_name

      def initialize(expressions, var, prop_name)
        @var = var.respond_to?(:var_name) ? var.var_name : var
        @expressions = expressions
        @prop_name = prop_name
        @var_name = @prop_name ? "#{@var.to_s}.#{@prop_name}" : @var.to_s
      end

      def to_function!(var = @var.to_s)
        @var_name = "#{@prop_name}(#{var})"
        self
      end

      def <(other)
        ExprOp.new(self, other, '<')
      end

      def <=(other)
        ExprOp.new(self, other, '<=')
      end

      def =~(other)
        ExprOp.new(self, other, '=~')
      end

      def >(other)
        ExprOp.new(self, other, '>')
      end

      def >=(other)
        ExprOp.new(self, other, '>=')
      end

      # Only in 1.9
      if RUBY_VERSION > "1.9.0"
        eval %{
      def !=(other)
        ExprOp.new(self, other, "!=")
      end  }
      end

      def ==(other)
        ExprOp.new(self, other, "=")
      end

      def in?(values)
        binary_operator("", " IN [#{values.map{|x| %Q["#{x}"]}.join(',')}]")
      end

      def binary_operator(op, post_fix = "")
        ExprOp.new(self, nil, op, post_fix)
      end
    end

    module Variable
      def [](prop_name)
        Property.new(expressions, self, prop_name)
      end

      def as(v)
        @var_name = v
        self
      end

      def property?(p)
        p = Property.new(expressions, self, p)
        p.binary_operator("has")
      end

      def exist?
        p = Property.new(expressions, self, p)
        p.binary_operator("", " is null")
      end
    end

    module Matchable
      # This operator means related to, without regard to type or direction.
      # @param [Symbol, #var_name] other either a node (Symbol, #var_name)
      # @return [MatchRelLeft, MatchNode]
      def <=>(other)
        MatchNode.new(self, other, expressions, :both)
      end

      # This operator means outgoing related to
      # @param [Symbol, #var_name, String] other the relationship
      # @return [MatchRelLeft, MatchNode]
      def >(other)
        MatchRelLeft.new(self, other, expressions, :outgoing)
      end

      # This operator means any direction related to
      # @param (see #>)
      # @return [MatchRelLeft, MatchNode]
      def -(other)
        MatchRelLeft.new(self, other, expressions, :both)
      end

      # This operator means incoming related to
      # @param (see #>)
      # @return [MatchRelLeft, MatchNode]
      def <(other)
        MatchRelLeft.new(self, other, expressions, :incoming)
      end

      # Outgoing relationship to other node
      # @param [Symbol, #var_name] other either a node (Symbol, #var_name)
      # @return [MatchRelLeft, MatchNode]
      def >>(other)
        MatchNode.new(self, other, expressions, :outgoing)
      end

      # Incoming relationship to other node
      # @param [Symbol, #var_name] other either a node (Symbol, #var_name)
      # @return [MatchRelLeft, MatchNode]
      def <<(other)
        MatchNode.new(self, other, expressions, :incoming)
      end
    end

    class Start < Expression
      attr_reader :var_name
      include Variable
      include Matchable

      def initialize(var_name, expressions)
        @var_name = "#{var_name}#{expressions.size}"
        super(expressions, :start)
      end

    end

    class StartNode < Start
      attr_reader :nodes

      def initialize(nodes, expressions)
        super("n", expressions)
        @nodes = nodes
      end

      def to_s
        "#{var_name}=node(#{nodes.join(',')})"
      end
    end

    class StartRel < Start
      attr_reader :rels

      def initialize(rels, expressions)
        super("r", expressions)
        @rels = rels
      end

      def to_s
        "#{var_name}=relationship(#{rels.join(',')})"
      end
    end

    class NodeQuery < Start
      attr_reader :index_name, :query

      def initialize(index_class, query, index_type, expressions)
        super("n", expressions)
        @index_name = index_class.index_name_for_type(index_type)
        @query = query
      end

      def to_s
        "#{var_name}=node:#{index_name}(#{query})"
      end
    end

    class NodeLookup < Start
      attr_reader :index_name, :query

      def initialize(index_class, key, value, expressions)
        super("n", expressions)
        index_type = index_class.index_type(key.to_s)
        raise "No index on #{index_class} property #{key}" unless index_type
        @index_name = index_class.index_name_for_type(index_type)
        @query = %Q[#{key}="#{value}"]
      end

      def to_s
        %Q[#{var_name}=node:#{index_name}(#{query})]
      end

    end

    # The return statement in the cypher query
    class Return < Expression
      def initialize(name_or_ref, expressions)
        super(expressions, :return)
        @name_or_ref = name_or_ref
      end

      def to_s
        @name_or_ref.is_a?(Symbol) ? @name_or_ref.to_s : @name_or_ref.var_name
      end
    end


    class Match < Expression
      attr_reader :dir, :expressions, :left, :right, :var_name, :dir_op
      attr_accessor :algorithm, :next, :prev

      def initialize(left, right, expressions, dir, dir_op)
        super(expressions, :match)
        @var_name = "m#{expressions.size}"
        @dir = dir
        @dir_op = dir_op
        @prev = left if left.is_a?(Match)
        @left = left
        @right = right
      end

      def find_match_start
        c = self
        while (c.prev) do
          c = c.prev
        end
        c
      end

      def left_var_name
        @left.respond_to?(:var_name) ? @left.var_name : @left.to_s
      end

      def right_var_name
        @right.respond_to?(:var_name) ? @right.var_name : @right.to_s
      end

      def right_expr
        @right.respond_to?(:expr) ? @right.expr : right_var_name
      end

      def to_s
        curr = find_match_start
        result = algorithm ? "#{var_name} = #{algorithm}(" : ""
        begin
          result << curr.expr
        end while (curr = curr.next)
        result << ")" if algorithm
        result
      end
    end

    class MatchRelLeft < Match
      def initialize(left, right, expressions, dir)
        super(left, right, expressions, dir, dir == :incoming ? '<-' : '-')
      end

      # @param [Symbol,NodeVar,String] other part of the match cypher statement.
      # @return [MatchRelRight] the right part of an relationship cypher query.
      def >(other)
        expressions.delete(self)
        self.next = MatchRelRight.new(self, other, expressions, :outgoing)
      end

      # @see #>
      # @return (see #>)
      def <(other)
        expressions.delete(self)
        self.next = MatchRelRight.new(self, other, expressions, :incoming)
      end

      # @see #>
      # @return (see #>)
      def -(other)
        expressions.delete(self)
        self.next = MatchRelRight.new(self, other, expressions, :both)
      end

      # @return [String] a cypher string for this match.
      def expr
        if prev
          # we have chained more then one relationships in a match expression
          "#{dir_op}[#{right_expr}]"
        else
          # the right is an relationship and could be an expressions, e.g "r?"
          "(#{left_var_name})#{dir_op}[#{right_expr}]"
        end
      end
    end

    class MatchRelRight < Match
      # @param left the left part of the query
      # @param [Symbol,NodeVar,String] right part of the match cypher statement.
      def initialize(left, right, expressions, dir)
        super(left, right, expressions, dir, dir == :outgoing ? '->' : '-')
      end

      # @param [Symbol,NodeVar,String] other part of the match cypher statement.
      # @return [MatchRelLeft] the right part of an relationship cypher query.
      def >(other)
        expressions.delete(self)
        self.next = MatchRelLeft.new(self, other, expressions, :outgoing)
      end

      # @see #>
      # @return (see #>)
      def <(other)
        expressions.delete(self)
        self.next = MatchRelLeft.new(self, other, expressions, :incoming)
      end

      # @see #>
      # @return (see #>)
      def -(other)
        expressions.delete(self)
        self.next = MatchRelLeft.new(self, other, expressions, :both)
      end

      # @return [String] a cypher string for this match.
      def expr
        "#{dir_op}(#{right_var_name})"
      end
    end

    class MatchNode < Match
      attr_reader :dir_op

      def initialize(left, right, expressions, dir)
        dir_op = case dir
                   when :outgoing then
                     "-->"
                   when :incoming then
                     "<--"
                   when :both then
                     "--"
                 end
        super(left, right, expressions, dir, dir_op)
      end

      # @return [String] a cypher string for this match.
      def expr
        if prev
          # we have chained more then one relationships in a match expression
          "#{dir_op}(#{right_expr})"
        else
          # the right is an relationship and could be an expressions, e.g "r?"
          "(#{left_var_name})#{dir_op}(#{right_expr})"
        end
      end

      def <<(other)
        expressions.delete(self)
        self.next = MatchNode.new(self, other, expressions, :incoming)
      end

      def >>(other)
        expressions.delete(self)
        self.next = MatchNode.new(self, other, expressions, :outgoing)
      end

      # @param [Symbol,NodeVar,String] other part of the match cypher statement.
      # @return [MatchRelRight] the right part of an relationship cypher query.
      def >(other)
        expressions.delete(self)
        self.next = MatchRelLeft.new(self, other, expressions, :outgoing)
      end

      # @see #>
      # @return (see #>)
      def <(other)
        expressions.delete(self)
        self.next = MatchRelLeft.new(self, other, expressions, :incoming)
      end

      # @see #>
      # @return (see #>)
      def -(other)
        expressions.delete(self)
        self.next = MatchRelLeft.new(self, other, expressions, :both)
      end

    end

    # Represents an unbound node variable used in match statements
    class NodeVar
      include Variable
      include Matchable


      # @return the name of the variable
      attr_reader :var_name
      attr_reader :expressions

      def initialize(expressions, variables)
        @var_name = "v#{variables.size}"
        variables << self
        @expressions = expressions
      end

      # @return [String] a cypher string for this node variable
      def to_s
        var_name
      end

    end


    # represent an unbound relationship variable used in match,where,return statement
    class RelVar
      include Variable

      attr_reader :var_name, :expr, :expressions

      def initialize(expressions, variables, expr)
        variables << self
        @expr = expr
        @expressions = expressions
        guess = expr ? /([[:alpha:]]*)/.match(expr)[1] : ""
        @var_name = guess.empty? ? "v#{variables.size}" : guess
      end

      def rel_type
        Property.new(@expressions, self, 'type').to_function!
      end

      # @return [String] a cypher string for this relationship variable
      def to_s
        var_name
      end

    end


    class ExprOp < Expression

      attr_reader :left, :right, :op, :neg, :post_fix

      def initialize(left, right, op, post_fix = "")
        super(left.expressions, :where)
        @op = op
        @post_fix = post_fix
        self.expressions.delete(left)
        self.expressions.delete(right)
        @left = quote(left)
        if regexp?(right)
          @op = "=~"
          @right = to_regexp(right)
        else
          @right = right && quote(right)
        end
        @neg = nil
      end

      def separator
        " "
      end

      def quote(val)
        if val.respond_to?(:var_name)
          val.var_name
        else
          val.is_a?(String) ? %Q["#{val}"] : val
        end
      end

      def regexp?(right)
        @op == "=~" || right.is_a?(Regexp)
      end

      def to_regexp(val)
        %Q[/#{val.respond_to?(:source) ? val.source : val.to_s}/]
      end

      def &(other)
        ExprOp.new(self, other, "and")
      end

      def |(other)
        ExprOp.new(self, other, "or")
      end

      def -@
        @neg = "not"
        self
      end

      def not
        @neg = "not"
        self
      end

      # Only in 1.9
      if RUBY_VERSION > "1.9.0"
        eval %{
       def !
         @neg = "not"
         self
       end
       }
      end

      def left_to_s
        left.is_a?(ExprOp) ? "(#{left})" : left
      end

      def right_to_s
        right.is_a?(ExprOp) ? "(#{right})" : right
      end

      def to_s
        if @right
          neg ? "#{neg}(#{left_to_s} #{op} #{right_to_s})" : "#{left_to_s} #{op} #{right_to_s}"
        else
          # binary operator
          neg ? "#{neg}(#{op}(#{left_to_s}#{post_fix}))" : "#{op}(#{left_to_s}#{post_fix})"
        end
      end
    end

    class Where < Expression
      def initialize(expressions, where_statement = nil)
        super(expressions, :where)
        @where_statement = where_statement
      end

      def to_s
        @where_statement.to_s
      end
    end

    #class Algorithm < Expression
    #  def initialize(expressions, name)
    #    super(expressions)
    #  end
    #
    #  def prefix
    #    " WHERE"
    #  end
    #
    #  def to_s
    #    @where_statement.to_s
    #  end
    #
    #end
    # Creates a Cypher DSL query.
    # To create a new cypher query you must initialize it either an String or a Block.
    #
    # @example <tt>START n0=node(3) MATCH (n0)--(x) RETURN x</tt>`same as
    #   Cypher.new { start n = node(3); match n <=> :x; ret :x }.to_s
    #
    # @example <tt>START n0=node(3) MATCH (n0)-[r]->(x) RETURN r</tt> same as
    #   node(3) > :r > :x; :r
    #
    # @example <tt>START n0=node(3) MATCH (n0)-->(x) RETURN x</tt> same as
    #   node(3) >> :x; :x
    #
    # @param [String] query the query expressed as an string instead of an block/yield.
    # @yield the block which will be evaluated in the context of this object in order to create an Cypher Query string
    # @yieldreturn [Return, Object] If the return is not an instance of Return it will be converted it to a Return object (if possible).
    def initialize(query = nil, &dsl_block)
      @expressions = []
      @variables = []
      res = if query
              self.instance_eval(query)
            else
              self.instance_eval(&dsl_block)
            end
      unless res.kind_of?(Return)
        res.respond_to?(:to_a) ? ret(*res) : ret(res)
      end
    end


    # Does nothing, just for making the DSL easier to read (maybe).
    # @return self
    def match(*)
      self
    end

    # Does nothing, just for making the DSL easier to read (maybe)
    # @return self
    def start(*)
      self
    end

    def where(w=nil)
      Where.new(@expressions, w) if w.is_a?(String)
      self
    end

    # Specifies a start node by performing a lucene query.
    # @param [Class] index_class a class responsible for an index
    # @param [String] q the lucene query
    # @param [Symbol] index_type the type of index
    # @return [NodeQuery]
    def query(index_class, q, index_type = :exact)
      NodeQuery.new(index_class, q, index_type, @expressions)
    end

    # Specifies a start node by performing a lucene query.
    # @param [Class] index_class a class responsible for an index
    # @param [String, Symbol] key the key we ask for
    # @param [String, Symbol] value the value of the key we ask for
    # @return [NodeLookup]
    def lookup(index_class, key, value)
      NodeLookup.new(index_class, key, value, @expressions)
    end

    # Creates a node variable.
    # It will create different variables depending on the type of the first element in the nodes argument.
    # * Fixnum - it will be be used as neo_id  for start node(s) (StartNode)
    # * Symbol - it will create an unbound node variable with the same name as the symbol (NodeVar#as)
    # * empty array - it will create an unbound node variable (NodeVar)
    #
    # @param [Fixnum,Symbol,String] nodes the id of the nodes we want to start from
    # @return [StartNode, NodeVar]
    def node(*nodes)
      if nodes.first.is_a?(Symbol)
        NodeVar.new(@expressions, @variables).as(nodes.first)
      elsif !nodes.empty?
        StartNode.new(nodes, @expressions)
      else
        NodeVar.new(@expressions, @variables)
      end
    end

    # Similar to #node
    # @return [StartRel, RelVar]
    def rel(*rels)
      if rels.first.is_a?(Fixnum)
        StartRel.new(rels, @expressions)
      elsif rels.first.is_a?(Symbol)
        RelVar.new(@expressions, @variables, "").as(rels.first)
      elsif rels.first.is_a?(String)
        RelVar.new(@expressions, @variables, rels.first)
      else
        raise "Unknown arg #{rels.inspect}"
      end
    end

    # Specifies a return statement.
    # Notice that this is not needed, since the last value of the DSL block will be converted into one or more
    # return statements.
    # @param [Symbol, #var_name] returns a list of variables we want to return
    # @return [Return]
    def ret(*returns)
      returns.each { |ret| Return.new(ret, @expressions) }
      @expressions.last
    end

    def shortest_path(&block)
      match = instance_eval(&block)
      match.algorithm = 'shortestPath'
      match.find_match_start
    end

    # Converts the DSL query to a cypher String which can be executed by cypher query engine.
    def to_s
      clause = nil
      @expressions.map do |expr|
        expr_to_s = expr.clause != clause ? "#{expr.prefix} #{expr.to_s}" : "#{expr.separator}#{expr.to_s}"
        clause = expr.clause
        expr_to_s
      end.join
    end
  end
end
