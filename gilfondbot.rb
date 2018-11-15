require 'capybara'
require 'capybara/dsl'
require 'capybara/poltergeist'
require 'net/http'
require 'uri'

#
# Автоматизация для gilfondrt.ru
#
# Ищет квартиры с нужным числом комнат, добавляет заявки, расставляет приоритеты
#
# При запуске используются следующие переменные окружения:
#   GF_RTY_NAME - имя поручения, например, "Поручение №11318 Верхнеуслонский район"
#   GF_NUMFILE - номер личного дела, например, "1111-111111-111111"
#   GF_PASSWORD - пароль от личного кабинета
#   GF_NROOMS - желаемое количество комнат через запятую, например, NROOMS = "1,2,3"
#   GF_TG_TOKEN - токен телеграм бота
#   GF_TG_CHAT_ID - ID чата с ботом (см. https://www.forsomedefinition.com/automation/creating-telegram-bot-notifications/)
#   GF_FLAT_TTL - время в секундах, после которого квартира считается вновь появившейся
#
# Требует наличия phantomjs (http://phantomjs.org/download.html)
#
RTY_NAME = ENV['GF_RTY_NAME']
NUMFILE = ENV['GF_NUMFILE']
PASSWORD = ENV['GF_PASSWORD']
NROOMS = ENV['GF_NROOMS']
TG_TOKEN = ENV['GF_TG_TOKEN']
TG_CHAT_ID = ENV['GF_TG_CHAT_ID']
FLAT_TTL = ENV['GF_FLAT_TTL']

class GilfondBot
  include Capybara::DSL

  # rty_names: string
  # numfile: string
  # password: string
  # nrooms: string, comma-separated
  # notifier: interface: notify_on_add(n_added)
  # seen_db: interface: seen?(flat_id), saw!(flat_id)
  def initialize(rty_name:, numfile:, password:, nrooms:, notifier:, seen_db:)
    @options = {
      rty_name: rty_name,
      numfile: numfile,
      password: password,
      nrooms: nrooms,
    }
    @notifier = notifier
    @seen_db = seen_db
    Capybara.default_driver = :poltergeist
    # Capybara.default_driver = :selenium
    Capybara.save_path = 'screens'
    Capybara.default_max_wait_time = 10
    login
  end

  def login
    set_cookies
    visit "https://mail.gilfondrt.ru/private/add_flat.php"
    if has_content? "Номер учетного дела (####-######-######)"
      fill_in "numfile", with: @options[:numfile]
      fill_in "pass", with: @options[:password]
      click_button "Подтвердить"
      visit "https://mail.gilfondrt.ru/private/add_flat.php"
    end
    save_cookies
  end

  def set_cookies
    visit "https://mail.gilfondrt.ru/private/auth.php"
    cookies = Marshal.load(File.read("cookies.dump")) rescue {}
    page.driver.clear_cookies
    cookies.each do |name, cookie|
      page.driver.set_cookie(name, cookie.value, {
        domain: cookie.domain,
        path: cookie.path,
        secure: cookie.secure?,
        httponly: cookie.httponly?,
        samesite: cookie.samesite,
        expires: cookie.expires,
      })
    end
  end

  def save_cookies
    cookies = page.driver.cookies
    File.write("cookies.dump", Marshal.dump(cookies))
  end

  def add_flats
    visit "https://mail.gilfondrt.ru/private/add_flat.php"
    select @options[:rty_name], from: "cmn_id"

    unless has_css?('select[name="rty_id"]')
      save("add_flats.no_select")
      return
    end

    houses = find('select[name="rty_id"]').all("option").collect(&:text).select{|h| h.strip != ""}
    houses.each do |house|
      select house, from: "rty_id"
      # find matching open flats and add them
      trs = find('.flatList table').all('tr[id].open')
        .select{ |tr| !@seen_db.seen?(tr[:id]) }
        .select{ |tr| wanted_rooms.include?(tr.all('td')[3].text.to_i) }
      trs.each do |tr|
        notify_on_add(tr[:id])
        tr.click_link("добавить")
        sleep(rand * 3)
      end
      save("add_flats.found_flats") if trs.size > 0
      # mark all flats as seen
      find('.flatList table').all('tr[id]').map{|tr| tr[:id]}.each{|id| @seen_db.saw!(id)}
    end
  rescue
    save("add_flats.exception")
    raise
  end

  def wanted_rooms
    @options[:nrooms].split(",").map(&:to_i)
  end

  def set_priorities
    visit "https://mail.gilfondrt.ru/private/requests.php"
    # visit "http://gfb.miga.impuls1.ru/pages/requests-red.html"

    old_priority = priority = all('table table.border_1 tr input[type="text"]').map(&:value).map(&:to_i).max || 0
    i = 0
    while all('table table.border_1 tr[bgcolor="#FF0000"] input[type="text"]').size > 0
      priority += i
      i += 1
      all('table table.border_1 tr[bgcolor="#FF0000"] input[type="text"]').each do |elem|
        priority += 1
        elem.set(priority.to_s)
      end
      click_button "Сохранить изменения"
    end
  rescue
    save("set_priorities")
    raise
  end

  def notify_on_add(id)
    @notifier.notify_on_add(n_added)
    flat_url = "https://mail.gilfondrt.ru/private/raitings_flat_2.php?flt_id=#{id}"
    @notifier.notify("Adding #{flat_url} Requests: https://mail.gilfondrt.ru/private/requests.php")
  end

  def save(name)
    fname = Time.now.strftime("%m%d-%H:%M.") + name
    page.save_screenshot("#{fname}.png")
    save_page("#{fname}.html")
  end
end

class Notifier
  def initialize(tg_token: nil, tg_chat_id: nil)
    @options = {
      tg_token: tg_token,
      tg_chat_id: tg_chat_id,
    }
  end

  def notify(text)
    uri = URI.parse("https://api.telegram.org/bot#{@options[:tg_token]}/sendMessage")
    Net::HTTP.post_form(uri, chat_id: @options[:tg_chat_id], text: text)
  end
end

class SeenDb
  def initialize(filename, ttl)
    @filename = filename
    @ttl = ttl
    @seen = Marshal.load(File.read(@filename)) rescue {}
  end

  def seen?(flat_id)
    @seen[flat_id] && @seen[flat_id] > Time.now - @ttl
  end

  def saw!(flat_id)
    @seen[flat_id] = Time.now
  end

  def self.with_db(filename, ttl, &block)
    db = SeenDb.new(filename, ttl)
    yield(db)
  ensure
    db.persist
  end

  def persist
    File.write(@filename, Marshal.dump(@seen))
  end
end

def run!
  SeenDb.with_db("seen.db", FLAT_TTL) do |seen_db|
    bot = GilfondBot.new(
      rty_name: RTY_NAME,
      numfile: NUMFILE,
      password: PASSWORD,
      nrooms: NROOMS,
      notifier: Notifier.new(tg_token: TG_TOKEN, tg_chat_id: TG_CHAT_ID),
      seen_db: seen_db,
    )

    bot.add_flats
    bot.set_priorities
  end
rescue Exception => e
  Notifier.new(tg_token: TG_TOKEN, tg_chat_id: TG_CHAT_ID)
    .notify("Exception occured:\n\n#{e.message}\n\n#{e.backtrace.join("\n")}")
end

run!
