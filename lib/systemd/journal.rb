require 'systemd/journal/native'
require 'systemd/journal/flags'
require 'systemd/journal/fields'
require 'systemd/journal_error'
require 'systemd/journal_entry'
require 'systemd/id128'

require 'systemd/ffi_size_t'

module Systemd
  # Class to allow interacting with the systemd journal.
  # To read from the journal, instantiate a new {Systemd::Journal}; to write to
  # the journal, use
  # TODO: re-implement writing
  class Journal
    include Enumerable

    # Returns a new instance of a Journal, opened with the provided options.
    # @param [Hash] opts optional initialization parameters.
    # @option opts [Integer] :flags a set of bitwise OR-ed
    #   {Systemd::Journal::Flags} which control what journal files are opened.
    #   Defaults to `0`, meaning all journals avaiable to the current user.
    # @option opts [String]  :path if provided, open the journal files living
    #   in the provided directory only.  Any provided flags will be ignored per
    #   since sd_journal_open_directory does not currently accept any flags.
    # @example Read only system journal entries
    #   j = Systemd::Journal.new(flags: Systemd::Journal::Flags::SYSTEM_ONLY)
    # @example Directly open a journal directory
    #   j = Systemd::Journal.new(
    #     path: '/var/log/journal/5f5777e46c5f4131bd9b71cbed6b9abf'
    #   )
    def initialize(opts = {})
      flags = opts[:flags] || 0
      path  = opts[:path]
      ptr   = FFI::MemoryPointer.new(:pointer, 1)

      rc = if path
             Native::sd_journal_open_directory(ptr, path, 0)
           else
             Native::sd_journal_open(ptr, flags)
           end

      raise JournalError.new(rc) if rc < 0

      @ptr = ptr.read_pointer
      ObjectSpace.define_finalizer(self, self.class.finalize(@ptr))
    end

    # Iterate over each entry in the journal, respecting the applied
    # conjunctions/disjunctions.
    # If a block is given, it is called with each entry until no more
    # entries remain.  Otherwise, returns an enumerator which can be chained.
    def each
      return to_enum(:each) unless block_given?

      seek(:head)
      yield current_entry while move_next
    end

    # Move the read pointer to the next entry in the journal.
    # @return [Boolean] True if moving to the next entry was successful.
    # @return [Boolean] False if unable to move to the next entry, indicating
    #   that the pointer has reached the end of the journal.
    def move_next
      if (rc = Native::sd_journal_next(@ptr)) < 0
        raise JournalError.new(rc) if rc < 0
      end
      rc > 0
    end

    # Move the read pointer forward by `amount` entries.
    # @return [Integer] the actual number of entries by which the read pointer
    #   moved. If this number is less than the requested amount, the read
    #   pointer has reached the end of the journal.
    def move_next_skip(amount)
      rc = Native::sd_journal_next_skip(@ptr, amount)
      raise JournalError.new(rc) if rc < 0
      rc
    end

    # Move the read pointer to the previous entry in the journal.
    # @return [Boolean] True if moving to the previous entry was successful.
    # @return [Boolean] False if unable to move to the previous entry,
    #   indicating that the pointer has reached the beginning of the journal.
    def move_previous
      if (rc = Native::sd_journal_previous(@ptr)) < 0
        raise JournalError.new(rc) if rc < 0
      end
      rc > 0
    end

    # Move the read pointer backwards by `amount` entries.
    # @return [Integer] the actual number of entries by which the read pointer
    #   was moved.  If this number is less than the requested amount, the read
    #   pointer has reached the beginning of the journal.
    def move_previous_skip(amount)
      rc = Native::sd_journal_previous_skip(@ptr, amount)
      raise JournalError.new(rc) if rc < 0
      rc
    end

    # Seek to a position in the journal.
    # Note: after seeking, you must call {#move_next} or {#move_previous}
    #   before you can call {#read_field} or {#current_entry}.
    #
    # @param [Symbol, Time] whence one of :head, :tail, or a Time instance.
    #   `:head` (or `:start`) will seek to the beginning of the journal.
    #   `:tail` (or `:end`) will seek to the end of the journal. When a `Time`
    #   is provided, seek to the journal entry logged closest to that time. When
    #   a String is provided, assume it is a cursor from {#cursor} and seek to
    #   that entry.
    # @return [True]
    def seek(whence)
      rc = case whence
           when :head, :start
             Native::sd_journal_seek_head(@ptr)
           when :tail, :end
             Native::sd_journal_seek_tail(@ptr)
           else
             if whence.is_a?(Time)
               # TODO: is this right? who knows.
               Native::sd_journal_seek_realtime_usec(@ptr, whence.to_i * 1_000_000)
             elsif whence.is_a?(String)
               Native::sd_journal_seek_cursor(@ptr, whence)
             else
               raise ArgumentError.new("Unknown seek type: #{whence.class}")
             end
           end

      raise JournalErrornew(rc) if rc < 0

      true
    end

    # Read the contents of the provided field from the current journal entry.
    #   {#move_next} or {#move_previous} must be called at least once after
    #   initialization or seeking prior to attempting to read data.
    # @param [String] field the name of the field to read.
    # @return [String] the value of the requested field.
    # @example Read the `MESSAGE` field from the current entry
    #   j = Systemd::Journal.new
    #   j.move_next
    #   puts j.read_field('MESSAGE')
    def read_field(field)
      len_ptr = FFI::MemoryPointer.new(:size_t, 1)
      out_ptr = FFI::MemoryPointer.new(:pointer, 1)

      rc = Native::sd_journal_get_data(@ptr, field.to_s.upcase, out_ptr, len_ptr)

      raise JournalError.new(rc) if rc < 0

      len = len_ptr.read_size_t
      out_ptr.read_pointer.read_string_length(len).split('=', 2).last
    end

    # Read the contents of all fields from the current journal entry.
    # If given a block, it will yield each field in the form of
    # `(fieldname, value)`.
    #
    # {#move_next} or {#move_previous} must be called at least once after
    # initialization or seeking prior to calling {#current_entry}
    #
    # @return [Hash] the contents of the current journal entry.
    # @example Print all items in the current entry
    #   j = Systemd::Journal.new
    #   j.move_next
    #   j.current_entry{ |field, value| puts "#{field}: #{value}" }
    def current_entry
      Native::sd_journal_restart_data(@ptr)

      len_ptr = FFI::MemoryPointer.new(:size_t, 1)
      out_ptr = FFI::MemoryPointer.new(:pointer, 1)
      results = {}

      while (rc = Native::sd_journal_enumerate_data(@ptr, out_ptr, len_ptr)) > 0
        len = len_ptr.read_size_t
        key, value = out_ptr.read_pointer.read_string_length(len).split('=', 2)
        results[key] = value

        yield(key, value) if block_given?
      end

      raise JournalError.new(rc) if rc < 0

      JournalEntry.new(results)
    end

    # Get the list of unique values stored in the journal for the given field.
    # If passed a block, each possible value will be yielded.
    # @return [Array] the list of possible values.
    # @example Fetch all possible boot ids from the journal
    #   j = Systemd::Journal.new
    #   j.query_unique('_BOOT_ID')
    # @example Enumerate machine IDs with a block
    #   j = Systemd::Journal.new
    #   j.query_unique('_MACHINE_ID') do |machine_id|
    #     puts "found machine id #{machine_id}"
    #   end
    def query_unique(field)
      results = []
      out_ptr = FFI::MemoryPointer.new(:pointer, 1)
      len_ptr = FFI::MemoryPointer.new(:size_t,  1)

      Native::sd_journal_restart_unique(@ptr)

      if (rc = Native::sd_journal_query_unique(@ptr, field.to_s.upcase)) < 0
        raise JournalError.new(rc)
      end

      while (rc = Native::sd_journal_enumerate_unique(@ptr, out_ptr, len_ptr)) > 0
        len = len_ptr.read_size_t
        results << out_ptr.read_pointer.read_string_length(len).split('=', 2).last

        yield results.last if block_given?
      end

      raise JournalError.new(rc) if rc < 0

      results
    end

    # Block until the journal is changed.
    # @param timeout_usec [Integer] the maximum number of microseconds to wait
    #   or `-1` to wait indefinitely.
    # @example Wait for an event for a maximum of 3 seconds
    #   j = Systemd::Journal.new
    #   j.seek(:tail)
    #   if j.wait(3 * 1_000_000)
    #     # event occurred
    #   end
    # @return [Nil] if the wait time was reached (no events occured).
    # @return [Symbol] :append if new entries were appened to the journal.
    # @return [Symbol] :invalidate if journal files were added/removed/rotated.
    def wait(timeout_usec = -1)
      rc = Native::sd_journal_wait(@ptr, timeout_usec)
      raise JournalError.new(rc) if rc.is_a?(Fixnum) && rc < 0
      rc == :nop ? nil : rc
    end

    # Add a filter to journal, such that only entries where the given filter
    # matches are returned.
    # {#move_next} or {#move_previous} must be invoked after adding a match
    # before attempting to read from the journal.
    # @param [String] field the column to filter on, e.g. _PID, _EXE.
    # @param [String] value the match to search for, e.g. '/usr/bin/sshd'
    # @return [nil]
    def add_match(field, value)
      match = "#{field.to_s.upcase}=#{value}"
      rc = Native::sd_journal_add_match(@ptr, match, match.length)
      raise JournalError.new(rc) if rc < 0
    end

    # Add an OR condition to the filter.  All previously added matches
    # and any matches added afterwards will be OR-ed together.
    # {#move_next} or {#move_previous} must be invoked after adding a match
    # before attempting to read from the journal.
    # @return [nil]
    # @example Filter entries returned using an OR condition
    #   j = Systemd::Journal.new
    #   j.add_match('PRIORITY', 5)
    #   j.add_match('_EXE', '/usr/bin/sshd')
    #   j.add_disjunction
    #   while j.move_next
    #     # current_entry is either an sshd event or
    #     # has priority 5
    #   end
    def add_disjunction
      rc = Native::sd_journal_add_disjunction(@ptr)
      raise JournalError.new(rc) if rc < 0
    end

    # Add an AND condition to the filter.  All previously added matches
    # and any matches added afterwards will be AND-ed together.
    # {#move_next} or {#move_previous} must be invoked after adding a match
    # before attempting to read from the journal.
    # @return [nil]
    # @example Filter entries returned using an AND condition
    #   j = Systemd::Journal.new
    #   j.add_match('PRIORITY', 5)
    #   j.add_match('_EXE', '/usr/bin/sshd')
    #   j.add_conjunction
    #   while j.move_next
    #     # current_entry is an sshd event with priority 5
    #   end
    def add_conjunction
      rc = Native::sd_journal_add_conjunction(@ptr)
      raise JournalError.new(rc) if rc < 0
    end

    # Remove all matches and conjunctions/disjunctions.
    # @return [nil]
    def clear_matches
      Native::sd_journal_flush_matches(@ptr)
    end

    # Get the number of bytes the Journal is currently using on disk.
    # If {Systemd::Journal::Flags::LOCAL_ONLY} was passed when opening the
    # journal,  this value will only reflect the size of journal files of the
    # local host, otherwise of all hosts.
    # @return [Integer] size in bytes
    def disk_usage
      size_ptr = FFI::MemoryPointer.new(:uint64)
      rc = Native::sd_journal_get_usage(@ptr, size_ptr)

      raise JournalError.new(rc) if rc < 0
      size_ptr.read_uint64
    end

    # Get the maximum length of a data field that will be returned.
    # Fields longer than this will be truncated.  Default is 64K.
    # @return [Integer] size in bytes.
    def data_threshold
      size_ptr = FFI::MemoryPointer.new(:size_t, 1)
      if (rc = Native::sd_journal_get_data_threshold(@ptr, size_ptr)) < 0
        raise JournalError.new(rc)
      end

      size_ptr.read_size_t
    end

    # Set the maximum length of a data field that will be returned.
    # Fields longer than this will be truncated.
    def data_threshold=(threshold)
      if (rc = Native::sd_journal_set_data_threshold(@ptr, threshold)) < 0
        raise JournalError.new(rc)
      end
    end

    # returns a string representing the current read position.
    # This string can be passed to {#seek} or {#cursor?}.
    # @return [String] a cursor token.
    def cursor
      out_ptr = FFI::MemoryPointer.new(:pointer, 1)
      if (rc = Native.sd_journal_get_cursor(@ptr, out_ptr)) < 0
        raise JournalError.new(rc)
      end

      out_ptr.read_pointer.read_string
    end

    # Check if the read position is currently at the entry represented by the
    # provided cursor value.
    # @param c [String] a cursor token returned from {#cursor}.
    # @return [Boolean] True if the current entry is the one represented by the
    # provided cursor, False otherwise.
    def cursor?(c)
      if (rc = Native.sd_journal_test_cursor(@ptr, c)) < 0
        raise JournalError.new(rc)
      end

      rc > 0
    end

    private

    def self.finalize(ptr)
      proc{ Native::sd_journal_close(ptr) unless ptr.nil? }
    end

  end
end
