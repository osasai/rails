module ActionView #:nodoc:
  class Template
    class Path
      attr_reader :path, :paths
      delegate :hash, :inspect, :to => :path

      def initialize(path)
        raise ArgumentError, "path already is a Path class" if path.is_a?(Path)
        @path = path.freeze
      end

      def to_s
        if defined?(RAILS_ROOT)
          path.to_s.sub(/^#{Regexp.escape(File.expand_path(RAILS_ROOT))}\//, '')
        else
          path.to_s
        end
      end

      def to_str
        path.to_str
      end

      def ==(path)
        to_str == path.to_str
      end

      def eql?(path)
        to_str == path.to_str
      end

      # Returns a ActionView::Template object for the given path string. The
      # input path should be relative to the view path directory,
      # +hello/index.html.erb+. This method also has a special exception to
      # match partial file names without a handler extension. So
      # +hello/index.html+ will match the first template it finds with a
      # known template extension, +hello/index.html.erb+. Template extensions
      # should not be confused with format extensions +html+, +js+, +xml+,
      # etc. A format must be supplied to match a formated file. +hello/index+
      # will never match +hello/index.html.erb+.
      def find_template(path)
        templates_in_path do |template|
          if template.accessible_paths.include?(path)
            return template
          end
        end
        nil
      end

      def find_by_parts(name, extensions = nil, prefix = nil, partial = nil)
        path = prefix ? "#{prefix}/" : ""
        
        name = name.to_s.split("/")
        name[-1] = "_#{name[-1]}" if partial
        
        path << name.join("/")

        template = nil

        Array(extensions).each do |extension|
          extensioned_path = extension ? "#{path}.#{extension}" : path
          template = find_template(extensioned_path) || find_template(path)
          break if template
        end
        template || find_template(path)
      end
      
      private
        def templates_in_path
          (Dir.glob("#{@path}/**/*/**") | Dir.glob("#{@path}/**")).each do |file|
            yield create_template(file) unless File.directory?(file)
          end
        end

        def create_template(file)
          Template.new(file.split("#{self}/").last, self)
        end
    end

    class EagerPath < Path
      def initialize(path)
        super

        @paths = {}
        templates_in_path do |template|
          template.load!
          template.accessible_paths.each do |path|
            @paths[path] = template
          end
        end
        @paths.freeze
      end

      def find_template(path)
        @paths[path]
      end
    end

    extend TemplateHandlers
    extend ActiveSupport::Memoizable
    include Renderable

    # Templates that are exempt from layouts
    @@exempt_from_layout = Set.new([/\.rjs$/])

    # Don't render layouts for templates with the given extensions.
    def self.exempt_from_layout(*extensions)
      regexps = extensions.collect do |extension|
        extension.is_a?(Regexp) ? extension : /\.#{Regexp.escape(extension.to_s)}$/
      end
      @@exempt_from_layout.merge(regexps)
    end

    attr_accessor :template_path, :filename, :load_path, :base_path
    attr_accessor :locale, :name, :format, :extension
    delegate :to_s, :to => :path

    def initialize(template_path, load_paths = [])
      template_path = template_path.dup
      @load_path, @filename = find_full_path(template_path, load_paths)
      @base_path, @name, @locale, @format, @extension = split(template_path)
      @base_path.to_s.gsub!(/\/$/, '') # Push to split method

      # Extend with partial super powers
      extend RenderablePartial if @name =~ /^_/
    end
    
    def load!
      @cached = true
      # freeze
    end    
    
    def accessible_paths
      paths = []

      if valid_extension?(extension)
        paths << path
        paths << path_without_extension
        if multipart?
          formats = format.split(".")
          paths << "#{path_without_format_and_extension}.#{formats.first}"
          paths << "#{path_without_format_and_extension}.#{formats.second}"
        end
      else
        # template without explicit template handler should only be reachable through its exact path
        paths << template_path
      end

      paths
    end
    
    def relative_path
      path = File.expand_path(filename)
      path.sub!(/^#{Regexp.escape(File.expand_path(RAILS_ROOT))}\//, '') if defined?(RAILS_ROOT)
      path
    end
    memoize :relative_path
    
    def source
      File.read(filename)
    end
    memoize :source
    
    def exempt_from_layout?
      @@exempt_from_layout.any? { |exempted| path =~ exempted }
    end    
    
    def path_without_extension
      [base_path, [name, locale, format].compact.join('.')].compact.join('/')
    end
    memoize :path_without_extension    

    def path_without_format_and_extension
      [base_path, [name, locale].compact.join('.')].compact.join('/')
    end
    memoize :path_without_format_and_extension
    
    def path
      [base_path, [name, locale, format, extension].compact.join('.')].compact.join('/')
    end
    memoize :path
    
    def mime_type
      Mime::Type.lookup_by_extension(format) if format && defined?(::Mime)
    end
    memoize :mime_type      
    
  private
    
    def format_and_extension
      (extensions = [format, extension].compact.join(".")).blank? ? nil : extensions
    end
    memoize :format_and_extension

    def multipart?
      format && format.include?('.')
    end

    def content_type
      format.gsub('.', '/')
    end

    def mtime
      File.mtime(filename)
    end
    memoize :mtime

    def method_segment
      relative_path.to_s.gsub(/([^a-zA-Z0-9_])/) { $1.ord }
    end
    memoize :method_segment

    def stale?
      File.mtime(filename) > mtime
    end

    def recompile?
      !@cached
    end

    def valid_extension?(extension)
      !Template.registered_template_handler(extension).nil?
    end

    def valid_locale?(locale)
      I18n.available_locales.include?(locale.to_sym)
    end

    def find_full_path(path, load_paths)
      load_paths = Array(load_paths) + [nil]
      load_paths.each do |load_path|
        file = load_path ? "#{load_path.to_str}/#{path}" : path
        return load_path, file if File.file?(file)
      end
      raise MissingTemplate.new(load_paths, path)
    end

    # Returns file split into an array
    #   [base_path, name, locale, format, extension]
    def split(file)
      if m = file.to_s.match(/^(.*\/)?([^\.]+)\.(.*)$/)
        base_path = m[1]
        name = m[2]
        extensions = m[3]
      else
        return
      end

      locale = nil
      format = nil
      extension = nil

      if m = extensions.split(".")
        if valid_locale?(m[0]) && m[1] && valid_extension?(m[2]) # All three
          locale = m[0]
          format = m[1]
          extension = m[2]
        elsif m[0] && m[1] && valid_extension?(m[2]) # Multipart formats
          format = "#{m[0]}.#{m[1]}"
          extension = m[2]
        elsif valid_locale?(m[0]) && valid_extension?(m[1]) # locale and extension
          locale = m[0]
          extension = m[1]
        elsif valid_extension?(m[1]) # format and extension
          format = m[0]
          extension = m[1]
        elsif valid_extension?(m[0]) # Just extension
          extension = m[0]
        else # No extension
          format = m[0]
        end
      end

      [base_path, name, locale, format, extension]
    end
  end
end
