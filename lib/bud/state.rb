module Bud
  ######## methods for registering collection types
  private
  def check_collection_name(name)
    if @tables.has_key? name or @lattices.has_key? name
      raise Bud::CompileError, "collection already exists: #{name}"
    end

    # Rule out collection names that use reserved words, including
    # previously-defined method names.
    reserved = eval "defined?(#{name})"
    unless reserved.nil?
      raise Bud::CompileError, "symbol :#{name} reserved, cannot be used as collection name"
    end
  end

  def define_collection(name)
    check_collection_name(name)

    self.singleton_class.send(:define_method, name) do |*args, &blk|
      if blk.nil?
        return @tables[name]
      else
        return @tables[name].pro(&blk)
      end
    end
  end

  def define_lattice(name)
    check_collection_name(name)

    self.singleton_class.send(:define_method, name) do |*args|
      return @lattices[name]
    end
  end

  public

  def input # :nodoc: all
    true
  end

  def output # :nodoc: all
    false
  end

  # declare a transient collection to be an input or output interface
  def interface(mode, name, schema=nil)
    t_provides << [name.to_s, mode]
    scratch(name, schema)
  end

  # declare an in-memory, non-transient collection.  default schema <tt>[:key] => [:val]</tt>.
  def table(name, schema=nil)
    define_collection(name)
    @tables[name] = Bud::BudTable.new(name, self, schema)
  end

  # declare a syncronously-flushed persistent collection.  default schema <tt>[:key] => [:val]</tt>.
  def sync(name, storage, schema=nil)
    define_collection(name)
    case storage
    when :dbm
      @tables[name] = Bud::BudDbmTable.new(name, self, schema)
      @dbm_tables[name] = @tables[name]
    when :tokyo
      @tables[name] = Bud::BudTcTable.new(name, self, schema)
      @tc_tables[name] = @tables[name]
    else
      raise Bud::Error, "unknown synchronous storage engine #{storage.to_s}"
    end
  end

  def store(name, storage, schema=nil)
    define_collection(name)
    case storage
    when :zookeeper
      # treat "schema" as a hash of options
      options = schema
      raise Bud::Error, "Zookeeper tables require a :path option" if options[:path].nil?
      options[:addr] ||= "localhost:2181"
      @tables[name] = Bud::BudZkTable.new(name, options[:path], options[:addr], self)
      @zk_tables[name] = @tables[name]
    else
      raise Bud::Error, "unknown async storage engine #{storage.to_s}"
    end
  end

  # declare a transient collection.  default schema <tt>[:key] => [:val]</tt>
  def scratch(name, schema=nil)
    define_collection(name)
    @tables[name] = Bud::BudScratch.new(name, self, schema)
  end

  def readonly(name, schema=nil)
    define_collection(name)
    @tables[name] = Bud::BudReadOnly.new(name, self, schema)
  end

  # declare a scratch in a bloom statement lhs.  schema inferred from rhs.
  def temp(name)
    define_collection(name)
    # defer schema definition until merge
    @tables[name] = Bud::BudTemp.new(name, self, nil, true)
  end

  # declare a transient network collection.  default schema <tt>[:address, :val] => []</tt>
  def channel(name, schema=nil, loopback=false)
    define_collection(name)
    @tables[name] = Bud::BudChannel.new(name, self, schema, loopback)
    @channels[name] = @tables[name]
  end

  # declare a transient network collection that delivers facts back to the
  # current Bud instance. This is syntax sugar for a channel that always
  # delivers to the IP/port of the current Bud instance. Default schema
  # <tt>[:key] => [:val]</tt>
  def loopback(name, schema=nil)
    schema ||= {[:key] => [:val]}
    channel(name, schema, true)
  end

  # declare a collection to be read from +filename+.  rhs of statements only
  def file_reader(name, filename, delimiter='\n')
    define_collection(name)
    @tables[name] = Bud::BudFileReader.new(name, filename, delimiter, self)
  end

  # declare a collection to be auto-populated every +period+ seconds.  schema <tt>[:key] => [:val]</tt>.
  # rhs of statements only.
  def periodic(name, period=1)
    define_collection(name)
    raise Bud::Error if @periodics.has_key? [name]
    @periodics << [name, period]
    @tables[name] = Bud::BudPeriodic.new(name, self)
  end

  def terminal(name) # :nodoc: all
    if defined?(@terminal) && @terminal != name
      raise Bud::Error, "can't register IO collection #{name} in addition to #{@terminal}"
    else
      @terminal = name
    end
    define_collection(name)
    @tables[name] = Bud::BudTerminal.new(name, [:line], self)
    @channels[name] = @tables[name]
  end

  # Define methods to implement the state declarations for every registered kind
  # of lattice.
  def load_lattice_defs
    Bud::Lattice.global_ord_maps.each_key do |m|
      next if RuleRewriter::MONOTONE_WHITELIST.has_key? m
      if Bud::BudCollection.instance_methods.include? m.to_s
        puts "ord_map #{m} conflicts with non-monotonic method in BudCollection"
      end
    end

    Bud::Lattice.global_morphs.each_key do |m|
      next if RuleRewriter::MONOTONE_WHITELIST.has_key? m
      if Bud::BudCollection.instance_methods.include? m.to_s
        puts "morphism #{m} conflicts with non-monotonic method in BudCollection"
      end
    end

    # Sanity-check lattice definitions
    # XXX: We should do this only once per lattice
    Bud::Lattice.lattice_kinds.each do |lat_name, klass|
      unless klass.method_defined? :merge
        raise Bud::CompileError, "lattice #{lat_name} does not define a merge function"
      end

      # If a method is marked as an ord_map in any lattice, every lattice that
      # declares a method of that name must also mark it as an ord_map.
      meth_list = klass.instance_methods(false)
      Bud::Lattice.global_ord_maps.each_key do |m|
        next unless meth_list.include? m.to_s
        unless klass.ord_maps.has_key? m
          raise Bud::CompileError, "method #{m} in #{lat_name} must be an ord_map"
        end
      end

      # Apply a similar check for morphs
      Bud::Lattice.global_morphs.each_key do |m|
        next unless meth_list.include? m.to_s
        unless klass.morphs.has_key? m
          raise Bud::CompileError, "method #{m} in #{lat_name} must be a morph"
        end
      end

      # Similarly, check for non-monotone methods that are found in the builtin
      # list of monotone operators
      meth_list.each do |m_str|
        m = m_str.to_sym
        next unless RuleRewriter::MONOTONE_WHITELIST.has_key? m
        unless klass.ord_maps.has_key?(m) || klass.morphs.has_key?(m)
          raise Bud::CompileError, "method #{m} in #{lat_name} must be monotone"
        end
      end

      # We want to define the lattice state declaration function and give it a
      # default parameter; in Ruby 1.8, that can only be done using "*args"
      self.singleton_class.send(:define_method, lat_name) do |*args|
        collection_name, opts = args
        opts ||= {}
        opts = opts.clone       # Be paranoid
        opts[:scratch] ||= false

        define_lattice(collection_name)
        @lattices[collection_name] = Bud::LatticeWrapper.new(collection_name, klass,
                                                             opts[:scratch], self)
      end
    end
  end
end
