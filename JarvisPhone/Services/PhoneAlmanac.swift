import Foundation
import CoreLocation

enum PhoneAlmanac {
    enum Period: Equatable { case now, today, tomorrow, afterTomorrow, week }
    enum Request: Equatable {
        case time, dateAndTime, date(Int), weekday(Int)
        case weather(Period, String?)
    }

    // The caller supplies accent-folded pt-BR text with the wake word removed.
    static func request(_ text: String) -> Request? {
        var query = text.replacingOccurrences(of: #"^(?:(?:me )?(?:diz|diga|fala|fale|mostra|mostre|informa|informe)|(?:voce )?(?:pode|consegue) me (?:dizer|falar)|quero saber) "#,
                                              with: "", options: .regularExpression)
        func matches(_ pattern: String) -> Bool {
            query.range(of: "^(?:" + pattern + ")$", options: .regularExpression) != nil
        }
        if matches(#"(?:(?:qual|quais)(?: e| sao)? )?(?:a )?(?:data e (?:a )?hora|hora e (?:a )?data)(?: de hoje| atual| atuais| agora)?"#) { return .dateAndTime }
        let phone = #"(?: (?:do|no|da|na|de|em)(?: meu| minha)? (?:iphone|celular|telefone|tela|aparelho|dispositivo))?"#
        if matches(#"(?:(?:que|quais) horas?(?: sao| e| sao agora| sao agora mesmo| agora)?|(?:qual (?:e )?(?:a |o )?|(?:veja|ver) a |a )?(?:hora|horario)(?: (?:agora|atual|local))?)"# + phone) { return .time }
        if matches(#"(?:que dia (?:e|eh) (?:hoje|amanha)|que dia e|qual (?:e )?(?:a )?data(?: (?:de )?(?:hoje|amanha))?|(?:a )?data(?: (?:de )?(?:hoje|amanha))?|(?:qual )?o dia de hoje|hoje e (?:dia|que dia)(?: quanto)?)"#) {
            return .date(query.contains("amanha") ? 1 : 0)
        }
        if matches(#"(?:(?:qual|que) (?:o |e o |e )?dia da semana(?: e| sera| cai)?(?: hoje| amanha)?|dia da semana(?: de)?(?: hoje| amanha)?|(?:hoje|amanha) e (?:qual|que) dia da semana)"#) {
            return .weekday(query.contains("amanha") ? 1 : 0)
        }

        var period: Period?
        let periods: [(String,Period)] = [
            (#"\bdepois de amanha\b"#, .afterTomorrow),
            (#"\b(?:(?:para|pra|durante) (?:a |esta |essa )?|(?:desta|dessa|nesta|nessa|esta|essa|da|na|a) )?(?:semana(?: inteira)?|(?:os )?proximos sete dias|(?:os )?proximos 7 dias)\b"#, .week),
            (#"\b(?:(?:para|pra|de) )?amanha\b"#, .tomorrow),
            (#"\b(?:(?:para|pra|de) )?hoje\b"#, .today),
            (#"\bagora\b"#, .now)
        ]
        for (pattern, selected) in periods {
            if let range = query.range(of: pattern, options: .regularExpression) {
                period = selected
                query.removeSubrange(range)
                break
            }
        }
        query = query.split(separator: " ").joined(separator: " ")
        // A location can precede or follow the requested day.
        query = query.replacingOccurrences(of: #" (?:aqui(?: onde (?:eu )?estou)?|na minha (?:cidade|regiao|localizacao)|no meu bairro|por aqui)$"#, with: "", options: .regularExpression)
        var city: String?
        if let match = query.range(of: #" (?:em|na cidade de|aqui em|no|na) [a-z0-9]"#, options: .regularExpression),
           let start = query.index(match.upperBound, offsetBy: -1, limitedBy: query.startIndex) {
            let name = String(query[start...])
            guard name.count <= 100, name.range(of: #"\b(?:e depois|e (?:liga|toque|mande|leia|abre)|reuniao|agenda|mensagem)\b"#, options: .regularExpression) == nil else { return nil }
            if ["meu iphone","meu celular","meu telefone","iphone","celular","telefone","quarto","forno","pc","computador"].contains(name) { return nil }
            city = name
            query = String(query[..<match.lowerBound])
        }
        let current = #"(?:esta chovendo|ta chovendo|esta fazendo frio|ta frio|ta calor|como (?:esta|ta|e|anda|vai estar|vai ficar|vai ser)(?: o)? (?:tempo|clima)|(?:qual (?:e |esta |ta )?|como (?:esta|ta) |(?:me (?:diga|fala) )?)?(?:o |a )?(?:temperatura(?: atual)?|clima|tempo)|quantos graus(?: (?:esta|ta|faz|fazendo|esta fazendo|ta fazendo))?)"#
        let forecast = #"(?:qual (?:e )?)?(?:a )?previsao(?: (?:do |de )?(?:tempo|chuva))?"#
        let rain = #"(?:(?:sera que )?vai chover|pode chover|chove|tem (?:previsao de )?chuva|(?:qual (?:e )?)?(?:a )?(?:chance|probabilidade) de chuva)"#
        if matches(current) { return .weather(period ?? .now, city) }
        if matches(forecast) || matches(rain) { return .weather(period == .now ? .today : period ?? .today, city) }
        return nil
    }

    static func calendarReply(_ request: Request, date: Date = Date(), zone: TimeZone = .autoupdatingCurrent) -> String? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.timeZone = zone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        func format(day: Int, pattern: String) -> String {
            formatter.dateFormat = pattern
            return formatter.string(from: calendar.date(byAdding: .day, value: day, to: date) ?? date)
        }
        switch request {
        case .dateAndTime: return "Hoje é " + format(day: 0, pattern: "EEEE, d 'de' MMMM 'de' yyyy") + ", " + format(day: 0, pattern: "HH:mm") + "."
        case .time: return "Agora são " + format(day: 0, pattern: "HH:mm") + "."
        case .date(let day): return (day == 0 ? "Hoje é " : "Amanhã é ") + format(day: day, pattern: "EEEE, d 'de' MMMM 'de' yyyy") + "."
        case .weekday(let day): return (day == 0 ? "Hoje é " : "Amanhã é ") + format(day: day, pattern: "EEEE") + "."
        case .weather: return nil
        }
    }

    struct City: Decodable {
        let name: String
        let latitude: Double
        let longitude: Double
        let admin1: String?
        let country: String?
    }
    struct CitySearch: Decodable { let results: [City]? }
    struct Forecast: Decodable {
        struct Current: Decodable { let temperature_2m: Double?; let weather_code: Int? }
        struct Daily: Decodable {
            let time: [String]
            let weather_code: [Int?]
            let temperature_2m_min: [Double?]
            let temperature_2m_max: [Double?]
            let precipitation_probability_max: [Int?]
        }
        let current: Current?
        let daily: Daily
    }

    private static func get<T: Decodable>(_ base: String, _ parameters: [String:String], as: T.Type) async throws -> T {
        var components = URLComponents(string: base)!
        components.queryItems = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw URLError(.badURL) }
        let (bytes, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 9))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(T.self, from: bytes)
    }

    @MainActor private static let location = LocationService()

    @MainActor static func reply(_ text: String, locked: Bool) async -> String? {
        guard let request = request(text) else { return nil }
        if let reply = calendarReply(request) { return reply }
        guard case let .weather(period, cityName) = request else { return nil }
        let lat: Double, lon: Double, place: String
        do {
            if let cityName {
                let search = try await get("https://geocoding-api.open-meteo.com/v1/search", ["name":cityName, "language":"pt", "count":"1"], as: CitySearch.self)
                guard let city = search.results?.first else { return "Não encontrei a cidade \(cityName). Diga o nome da cidade e do estado." }
                lat = city.latitude; lon = city.longitude
                let region = city.admin1.flatMap { $0 == city.name ? nil : $0 } ?? city.country
                place = "Em " + city.name + (region.map { ", " + $0 } ?? "")
            } else {
                // A locked phone cannot present the first location authorization prompt.
                if locked && CLLocationManager().authorizationStatus == .notDetermined {
                    return "Diga uma cidade, ou abra o Jarvis uma vez para permitir a localização."
                }
                do {
                    let point = try await location.currentCoordinate()
                    lat = point.latitude; lon = point.longitude; place = "Na sua região"
                } catch {
                    return "Não consegui obter a localização do iPhone. Você pode dizer, por exemplo, “tempo em Curitiba”."
                }
            }
            let data = try await get("https://api.open-meteo.com/v1/forecast", [
                "latitude":String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), lat),
                "longitude":String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), lon),
                "current":"temperature_2m,weather_code", "daily":"weather_code,temperature_2m_min,temperature_2m_max,precipitation_probability_max",
                "timezone":"auto", "forecast_days":"7"
            ], as: Forecast.self)
            return forecastReply(data, period: period, place: place)
        } catch {
            return "Não consegui consultar a meteorologia pela internet agora. Tente novamente em instantes."
        }
    }

    private static func sky(_ code: Int?) -> String? {
        switch code {
        case 0: return "céu limpo"
        case 1: return "céu quase limpo"
        case 2: return "céu parcialmente nublado"
        case 3: return "céu encoberto"
        case 45,48: return "neblina"
        case 51,53,55,56,57: return "garoa"
        case 61,63,65,66,67: return "chuva"
        case 71,73,75,77,85,86: return "neve"
        case 80,81,82: return "pancadas de chuva"
        case 95,96,99: return "trovoadas"
        default: return nil
        }
    }

    static func forecastReply(_ data: Forecast, period: Period, place: String) -> String {
        let unavailable = "A previsão para esse período está indisponível."
        if period == .now {
            guard let temperature = data.current?.temperature_2m else { return unavailable }
            return "\(place), agora faz \(Int(temperature.rounded())) °C" + (sky(data.current?.weather_code).map { ", com " + $0 } ?? "") + "."
        }
        let days = data.daily
        if period == .week {
            guard days.time.count == 7, let low = days.temperature_2m_min.compactMap({ $0 }).min(),
                  let high = days.temperature_2m_max.compactMap({ $0 }).max() else { return unavailable }
            var reply = "\(place), nos próximos sete dias, temperaturas entre \(Int(low.rounded())) e \(Int(high.rounded())) °C."
            if let risk = days.precipitation_probability_max.compactMap({ $0 }).max(),
               let day = days.precipitation_probability_max.firstIndex(of: risk), days.time.indices.contains(day) {
                if risk == 0 { reply += " A previsão indica 0% de chance de chuva para os sete dias." }
                else {
                    let iso = DateFormatter()
                    iso.locale = Locale(identifier: "en_US_POSIX")
                    iso.timeZone = TimeZone(secondsFromGMT: 0)
                    iso.dateFormat = "yyyy-MM-dd"
                    if let date = iso.date(from: days.time[day]) {
                        iso.locale = Locale(identifier: "pt_BR"); iso.dateFormat = "EEEE"
                        reply += " A maior chance de chuva é \(risk)%, \(iso.string(from: date))."
                    }
                }
            }
            return reply
        }
        let index = period == .afterTomorrow ? 2 : period == .tomorrow ? 1 : 0
        guard days.time.indices.contains(index), days.temperature_2m_min.indices.contains(index), days.temperature_2m_max.indices.contains(index),
              let low = days.temperature_2m_min[index], let high = days.temperature_2m_max[index] else { return unavailable }
        let day = ["hoje","amanhã","depois de amanhã"][index]
        var reply = "\(place), \(day), mínima de \(Int(low.rounded())) e máxima de \(Int(high.rounded())) °C."
        if period == .today, let now = data.current?.temperature_2m {
            reply += " Agora faz \(Int(now.rounded())) °C" + (sky(data.current?.weather_code).map { ", com " + $0 } ?? "") + "."
        }
        if days.weather_code.indices.contains(index), let condition = sky(days.weather_code[index]) {
            reply += " Previsão de \(condition)."
        }
        if days.precipitation_probability_max.indices.contains(index), let chance = days.precipitation_probability_max[index] {
            reply += " Chance de chuva de \(chance)%."
        }
        return reply
    }
}