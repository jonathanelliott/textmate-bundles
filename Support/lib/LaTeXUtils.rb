require 'strscan'
# The LaTeX module contains a lot of methods useful when dealing with LaTeX
# files.
#
# Author:: Charilaos Skiadas
# Date:: 12/21/2006
module LaTeX
  # Simple conversion of bib field names to a simpler form
  def e_var(name)
    name.gsub(/[^a-zA-Z0-9\-_]/,"").gsub(/\-/,"_")
  end
  # Implements general methods that give information about the LaTeX document. 
  # Most of these commands recurse into \included files.
  class <<self
    # Returns an array of the label names. If you want actual Label objects, 
    # then use FileScanner.label_scan
    def get_labels
      return FileScanner.label_scan(ENV["TM_LATEX_MASTER"] || ENV["TM_FILEPATH"]).map{|i| i.label}.sort
    end
    # Returns an array of the citation objects. If you only want the citekeys, 
    # use LaTeX.get_citekeys
    def get_citations
      return FileScanner.cite_scan(ENV["TM_LATEX_MASTER"] || ENV["TM_FILEPATH"]).map{|i| i}.sort { |a,b| a.citekey <=> b.citekey }
    end
    # Returns an array of the citekeys in the document.
    def get_citekeys
      self.get_citations.map{|i| i["citekey"]}.uniq
    end
    # Returns the path to the TeX binaries, or raises an exception if it can't find them.
    def tex_path
      # First try directly
      return "" unless `which kpsewhich`.match(/^no kpsewhich/)
      # Then try some specific paths
      locs = ["/usr/texbin/",
              "/usr/local/teTeX/bin/powerpc-apple-darwin-current/",
              "/opt/local/bin/"]
      locs.each do |loc|
        return loc if File.exist?(loc+"kpsewhich")
      end
#     If all else fails, rely on /etc/profile. For most people, we should never make it here.
      loc = `. /etc/profile; which kpsewhich`
      return loc.gsub(/kpsewhich$/,"") unless loc.match(/^no kpsewhich/)
      raise "The tex binaries cannot be located!"
    end
    # Uses kpsewhich to locate the file with name +filename+ and +extension+.
    # +relative+ determines an explicit path that should be included in the
    # paths to look at when searching for the file. This will typically be the
    # path to the root document.
    def find_file(filename, extension, relative)
      filename.gsub!(/\.#{extension}$/,"")
      if filename.match(/^\//) # If it is an absolute path, return it
        filename = filename + ".#{extension}"
        return filename if File.exist?(filename)
        return nil
      end
      texpath = LaTeX.tex_path
      @@paths ||= Hash.new
      @@paths[extension] ||= ([`#{texpath}kpsewhich -show-path=#{extension}`.chomp.split(/:!!|:/)].flatten.map{|i| i.sub(/\/*$/,'/')}).unshift(relative).unshift("")
      return "#{filename}.#{extension}" if File.exist?("#{filename}.#{extension}")
      @@paths[extension].each do |path|
        testpath = File.expand_path(File.join(path,filename + "." + extension))
        return testpath if File.exist?(testpath)
      end
      return nil
    end
    # Processes the .bib file with title +file+, and returns an array of the
    # Citation objects.
    def parse_bibfile(file)
      raise "Could not locate file #{file.to_s}" if (file.nil? or !File.exist?(file))
      text = File.read(file)
      entries = text.scan(/^\s*@[^\{]*\{.*?(?=\n[ \t]*@|\z)/m)
      citations = entries.map do |text|
        c = Citation.new
        s = StringScanner.new(text)
        s.scan(/\s+@/)
        c["bibtype"] = s.scan(/[^\s\{]+/)
        s.scan(/\s*\{/)
        c["citekey"] = s.scan(/[^\s,]+(?=\s*,)/)
        if c["citekey"].nil?
          c = nil
          next
        end
        # puts "Found citekey: #{c["citekey"]}"
        s.scan(/\s*,/)
        until s.eos? or s.scan(/\s*\,?\s*\}/) do
          s.scan(/\s+/)
          key = s.scan(/[\w\-]+/)
          unless s.scan(/\s*=\s*/) then
            s.scan(/[^@]*/m)
            c=nil
            next
          end
          # puts "Found key: #{key}"
          contents = ""
          nest_level = 0
          until nest_level <= 0 and s.check(/[\},]/) do
            contents << (s.scan(/[^\{\}#{if nest_level == 0 then "," else "" end}]+/) || "")
            if s.scan(/\{/) then
              contents << "\{" unless nest_level == 0
              nest_level += 1
            elsif s.check(/\}/) then
              nest_level -= 1
              contents << "\}" unless nest_level <= 0
              s.scan(/\}/) unless nest_level == -1
            end
          end
          c[key] = contents
          # puts "Found contents: #{contents}"
          raise "Unexpected end of bib entry" unless s.scan(/\s*(\,|\})\s*/)
        end
        c
      end
      return citations.compact
    end
  end
  # A class implementing a recursive scanner.
  # +root+ is the file to start the scanning from.
  # +includes+ is a hash with keys regular expressions and values blocks of
  #   code called when that expression matches. The block is passed the
  #   matched groups in the kind of array returned by String#scan as argument,
  #   and must return the full path to the file to be recursively scanned.
  # +extractors+ is a similar hash, dealing with the bits of text to be
  #   matched. The block is passed as arguments the current filename, the
  #   current line number counting from 0, the matched groups in the kind
  #   of array returned by String#scan and finally the entire file contents.
  class FileScanner
    attr_accessor :root, :includes, :extractors
    # Creates a new scanner object. If the argument +old_scanner+ is a String,
    # then it is set as the +root+ file. Otherwise, it is used to read the
    # values of the three variables.
    def initialize(old_scanner=nil)
      if old_scanner then
        if old_scanner.is_a?(String) then
          @root = old_scanner
          self.set_defaults
        else
          @root = old_scanner.root
          @includes = old_scanner.includes
          @extractors = old_scanner.extractors
        end
      else
        self.set_defaults
      end
    end
    # Default values for the +includes+ hash.
    def set_defaults
      @includes = Hash.new
      @includes[/^[^%]*(?:\\include|\\input)\s*\{([^\}]*)\}/] = Proc.new {|m|
        m[0].split(",").map do |it|
          LaTeX.find_file( it.strip, "tex", File.dirname(@root) )
        end
      }
      @extractors = Hash.new
    end
    # Performs the recursive scanning.
    def recursive_scan
       raise "No root specified!" if @root.nil?
       raise "Could not find file #{@root}" unless File.exist?(@root)
       text = File.read(@root)
       text.each_with_index do |line, index|
         includes.each_pair do |regexp, block|
           line.scan(regexp).each do |m|
             newfiles = block.call(m)
             newfiles.each do |newfile|
               scanner = FileScanner.new(self)
               scanner.root = newfile.to_s
               scanner.recursive_scan
             end
           end
           extractors.each_pair { |regexp,block| 
             line.scan(regexp).each do |m|
               block.call(root,index,m,text)
             end
            }
         end
       end
    end
    # Creates a FileScanner object and uses it to read all the labels from the
    # document. Returns a list of Label objects.
    def self.label_scan(root)
      # LaTeX.set_paths
      labelsList = Array.new
      scanner = FileScanner.new(root)
      scanner.extractors[/^[^%]*\\label\{([^\}]*)\}/] = Proc.new do |filename, line, groups, text| 
        labelsList << Label.new(:file => filename, :line => line, :label => groups[0], :contents => text)
      end
      scanner.recursive_scan
      labelsList
    end
    # Creates a FileScanner object and uses it to read all the citations from
    # the document. Returns a list of Citation objects.
    def self.cite_scan(root)
      citationsList = Array.new
      scanner = FileScanner.new(root)
      bibitem_regexp = /^[^%]*\\bibitem(?:\[[^\]]*\])?\{([^\}]*)\}(.*)/
      biblio_regexp = /^[^%]*\\bibliography\s*\{([^\}]*)\}/
      scanner.extractors[bibitem_regexp] = Proc.new do |filename, line, groups, text|
      citationsList << Citation.new( "citekey" => groups[0], "cite_data" => groups[1])
      end
      scanner.extractors[biblio_regexp] = Proc.new do |filename, line, groups, text|
        groups[0].split(",").each do |it|
          file = LaTeX.find_file( it.strip, "bib", File.dirname(root) )
          citationsList += LaTeX.parse_bibfile(file)
          citationsList += LaTeX.parse_bibfile(ENV["TM_LATEX_BIB"]) unless ENV["TM_LATEX_BIB"].nil?
        end
      end
      scanner.recursive_scan
      citationsList
    end
  end
  class Label
    attr_accessor :file, :line, :label, :contents
    def initialize(hash)
      ["file","line","label","contents"].each do |key|
        eval("@#{key} = hash[:#{key}]")
      end
    end
    def to_s
      label
    end
    # Returns the text around the label.
    def context(chars = 40, countlines=false)
      if countlines then
        return contents.match(/(.*\n){#{chars/2}}.*\\label\{#{label}\}.*\n(.*\n){#{chars/2}}/)
      else
        return contents.gsub(/\s/,"").match(/.{#{chars/2}}\\label\{#{label}\}.{#{chars/2}}/)
      end
    end
    def file_line_label
      "#{file}:#{line}:#{label}"
    end
  end
  class Citation
    def initialize(hash = Hash.new)
      @hash = Hash.new
      hash.each_pair do |key,value|
        @hash[key.downcase] = value
      end
    end
    def []=(key,value)
      @hash[key.downcase] = value
    end
    def [](key)
      @hash[key.downcase]
    end
    def author
      @hash["author"] || @hash["editor"]
    end
    def title
      @hash["title"]
    end
    def description
      @hash["cite_data"] || "#{self.author}, #{self.title}"
    end
    def citekey
      @hash["citekey"]
    end
  end
end
# Example of use:
#
# include LaTeX
# # ar = FileScanner.cite_scan("/Users/haris/svnlocalrepos/repos/master.tex")
# ar = FileScanner.cite_scan("/Users/haris/Desktop/testing/Morten/test2.tex")
# puts ar.length
# ar.each do |citation|
#   puts citation.description
# end
