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
#
# Требует наличия phantomjs (http://phantomjs.org/download.html)
#
RTY_NAME = ENV['GF_RTY_NAME']
NUMFILE = ENV['GF_NUMFILE']
PASSWORD = ENV['GF_PASSWORD']
NROOMS = ENV['GF_NROOMS']
TG_TOKEN = ENV['GF_TG_TOKEN']
TG_CHAT_ID = ENV['GF_TG_CHAT_ID']

class GilfondBot
  include Capybara::DSL

  def initialize(rty_name:, numfile:, password:, nrooms:, notifier:)
    @options = {
      rty_name: rty_name,
      numfile: numfile,
      password: password,
      nrooms: nrooms,
    }
    @notifier = notifier
    Capybara.default_driver = :poltergeist
    Capybara.save_path = 'screens'
    login
  end

  def login
    visit "https://mail.gilfondrt.ru/private/auth.php"
    fill_in "numfile", with: @options[:numfile]
    fill_in "pass", with: @options[:password]
    click_button "Подтвердить"
    unless page.has_content?("Уважаемые участники жилищных программ!")
      puts "Ooops!"
    end
  end

  def add_flats
    visit "https://mail.gilfondrt.ru/private/add_flat.php"
    select @options[:rty_name], from: "cmn_id"

    houses = find('select[name="rty_id"]').all("option").collect(&:text).select{|h| h.strip != ""}
    n_added = 0
    houses.each do |house|
      select house, from: "rty_id"
      trs = find('.flatList table').all('tr[id].open')
        .select{ |tr| wanted_rooms.include?(tr.all('td')[3].text.to_i) }
      trs.each do |tr|
        tr.click_link("добавить")
        sleep(rand * 3)
      end
      n_added += trs.size
    end
    notify_on_add(n_added) if n_added > 0
  rescue Capybara::ElementNotFound
    # it's ok
  ensure
    page.save_screenshot("add_flats.#{Time.now}.png")
  end

  def wanted_rooms
    @option[:nrooms].split(",").map(&:to_i)
  end

  def set_priorities
    visit "https://mail.gilfondrt.ru/private/requests.php"
    priority = all('table table.border_1 tr[bgcolor="#FF0000"] input[type="text"]').map(&:value).map(&:to_i).max || 0
    all('table table.border_1 tr[bgcolor="#FF0000"] input[type="text"]').each do |elem|
      if elem.value.strip == ""
        priority += 1
        elem.value = priority.to_s
      end
    end
    click_button "Сохранить изменения"
  ensure
    page.save_screenshot("set_priorities.#{Time.now}.png")
  end

  def notify_on_add(n_added)
    @notifier.notify_telegram(n_added)
  end

  # def list_flats
  #   visit "https://mail.gilfondrt.ru/private/add_flat.php"
  #   select "Поручение №11318 Верхнеуслонский район", from: "cmn_id"

  #   houses = find('select[name="rty_id"]').all("option").collect(&:text).select{|h| h.strip != ""}
  #   houses.reduce({}) do |memo, house|
  #     select house, from: "rty_id"
  #     trs = find('.flatList table').all('tr[id]')
  #     memo[house] = trs.map do |tr|
  #         tds = tr.all('td')
  #         {
  #           tr_id: tr[:id],
  #           url: tds[1].find('a')[:href],
  #           number: tds[1].text,
  #           floor: tds[2].text,
  #           rooms: tds[3].text,
  #         }
  #       end
  #     memo
  #   end
  # end
end

class Notifier
  def initialize(tg_token: nil, tg_chat_id: nil)
    @options = {
      tg_token: tg_token,
      tg_chat_id: tg_chat_id,
    }
  end

  def notify_telegram(n_added)
    uri = URI.parse("https://api.telegram.org/bot#{@options[:tg_token]}/sendMessage")
    text = "Hooray! #{n_added} flat(s) added, check it out https://mail.gilfondrt.ru/private/requests.php"
    Net::HTTP.post_form(uri, chat_id: @options[:tg_chat_id], text: text)
  end
end

bot = GilfondBot.new(
  rty_name: RTY_NAME,
  numfile: NUMFILE,
  password: PASSWORD,
  nrooms: NROOMS,
  notifier: Notifier.new(tg_token: TG_TOKEN, tg_chat_id: TG_CHAT_ID)
)

bot.add_flats
bot.set_priorities
