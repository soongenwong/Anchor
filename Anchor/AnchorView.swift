import SwiftUI
internal import Combine

// MARK: - App Data Models
struct SpiritualGuidance: Codable, Identifiable {
    // Conforming to Codable to be decoded from the API response's JSON string.
    // Conforming to Identifiable is good practice.
    var id = UUID()
    let verseReference: String
    let verseText: String
    let explanation: String
    let prayer: String
    
    // Add CodingKeys to match the JSON we'll ask the AI to create.
    enum CodingKeys: String, CodingKey {
        case verseReference, verseText, explanation, prayer
    }
}

// --- NEW: Helper to Load API Key from Secrets.plist ---
struct ApiKeyLoader {
    static func getApiKey() -> String? {
        guard let path = Bundle.main.path(forResource: "Secrets", ofType: "plist"),
              let dict = NSDictionary(contentsOfFile: path) as? [String: AnyObject] else {
            print("❌ ERROR: Secrets.plist not found or could not be read.")
            return nil
        }
        
        guard let key = dict["GroqAPIKey"] as? String else {
            print("❌ ERROR: 'GroqAPIKey' not found in Secrets.plist.")
            return nil
        }
        
        // Basic check to see if the key has been filled in.
        if key == "YOUR_GROQ_API_KEY" || key.isEmpty {
            print("❌ ERROR: Please replace the placeholder API key in Secrets.plist with your actual key.")
            return nil
        }
        
        return key
    }
}

// --- NEW: Data Models for Groq API Interaction ---
struct GroqRequest: Codable {
    let messages: [GroqMessage]
    let model: String
    let temperature: Double
    let max_tokens: Int
    let top_p: Double
    let stop: String?
    let stream: Bool
    // This is crucial for getting reliable JSON output!
    let response_format: ResponseFormat?
    
    struct ResponseFormat: Codable {
        let type: String
    }
}

struct GroqMessage: Codable {
    let role: String
    let content: String
}

struct GroqResponse: Codable {
    let choices: [GroqChoice]
}

struct GroqChoice: Codable {
    let message: GroqResponseMessage
}

struct GroqResponseMessage: Codable {
    let content: String
}

// --- NEW: Groq API Service ---
@MainActor // Ensures UI updates happen on the main thread
class GroqAPIService: ObservableObject {
    
    private let apiKey: String?
    private let apiURL = URL(string: "https://api.groq.com/openai/v1/chat/completions")!

    @Published var isFetching = false
    @Published var errorMessage: String?
    
    init() {
        self.apiKey = ApiKeyLoader.getApiKey()
    }
    
    func generateGuidance(for userInput: String) async -> SpiritualGuidance? {
        guard let apiKey = apiKey else {
            self.errorMessage = "API Key is missing. Please check your Secrets.plist."
            return nil
        }
        
        isFetching = true
        errorMessage = nil
        
        let systemPrompt = """
        You are 'Anchor', an empathetic and gentle Spiritual Director AI. Your sole purpose is to provide comfort from the Christian Bible.
        
        The user will share a feeling or struggle. Your task is to:
        1.  Identify the core emotion (e.g., anxiety, sadness, fear, confusion).
        2.  Find a single, highly relevant, and comforting Bible verse that speaks directly to that emotion.
        3.  Write a brief, gentle, and pastoral explanation of how the verse applies to the user's situation.
        4.  Formulate a short, personal prayer based on the verse and the user's feeling.
        
        You MUST respond ONLY with a valid JSON object. Do not include any text, greetings, or explanations before or after the JSON.
        The JSON object must have this exact structure:
        {
          "verseReference": "Book Chapter:Verse(s)",
          "verseText": "The full text of the verse.",
          "explanation": "Your pastoral explanation.",
          "prayer": "The short prayer you formulated."
        }
        """
        
        let requestBody = GroqRequest(
            messages: [
                GroqMessage(role: "system", content: systemPrompt),
                GroqMessage(role: "user", content: userInput)
            ],
            model: "llama3-8b-8192", // The specified model
            temperature: 0.7,
            max_tokens: 1024,
            top_p: 1,
            stop: nil,
            stream: false,
            response_format: .init(type: "json_object")
        )
        
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        do {
            request.httpBody = try JSONEncoder().encode(requestBody)
        } catch {
            self.errorMessage = "Failed to encode request: \(error.localizedDescription)"
            isFetching = false
            return nil
        }
        
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            
            let groqResponse = try JSONDecoder().decode(GroqResponse.self, from: data)
            
            guard let contentString = groqResponse.choices.first?.message.content else {
                self.errorMessage = "API returned no content."
                isFetching = false
                return nil
            }
            
            // The content string itself is JSON, so we need to decode it again.
            guard let contentData = contentString.data(using: .utf8) else {
                self.errorMessage = "Could not convert API content to data."
                isFetching = false
                return nil
            }
            
            let guidance = try JSONDecoder().decode(SpiritualGuidance.self, from: contentData)
            
            isFetching = false
            return guidance
            
        } catch {
            self.errorMessage = "API request failed: \(error.localizedDescription)"
            print("❌ API ERROR: \(error)")
            isFetching = false
            return nil
        }
    }
}


// MARK: - Main Anchor View (UPDATED)
struct AnchorView: View {
    
    // --- UPDATED: State Management ---
    enum ViewState {
        case input, loading, response, error
    }
    
    @State private var currentState: ViewState = .input
    @State private var userInput: String = ""
    @State private var guidanceResponse: SpiritualGuidance?
    
    // Use @StateObject for the service to manage its lifecycle
    @StateObject private var groqService = GroqAPIService()

    private let placeholderText = "What's on your heart today?\n(e.g., I'm feeling anxious about work...)"
    
    var body: some View {
        ZStack {
            Color.BackgroundColor.edgesIgnoringSafeArea(.all)
            
            switch currentState {
            case .input:
                inputView
                    .transition(.asymmetric(insertion: .move(edge: .leading), removal: .move(edge: .leading)))
            case .loading:
                loadingView
                    .transition(.opacity)
            case .response:
                responseView
                    .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .trailing)))
            case .error:
                errorView
                    .transition(.opacity)
            }
        }
    }
    
    // MARK: - Subviews
    
    private var inputView: some View {
        VStack(spacing: 20) {
            Image(systemName: "anchor")
                .font(.system(size: 40, weight: .light))
                .foregroundColor(.AccentColor)
            Text("Anchor")
                .font(.largeTitle).fontWeight(.bold).foregroundColor(.PrimaryTextColor)
            Text("Find a quiet moment and share what's weighing on you. Let's find some peace in scripture together.")
                .font(.body).foregroundColor(.SecondaryTextColor).multilineTextAlignment(.center).padding(.horizontal)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $userInput)
                    .scrollContentBackground(.hidden).padding(12).background(Color.InputBackgroundColor)
                    .clipShape(RoundedRectangle(cornerRadius: 15)).frame(height: 200).foregroundColor(.PrimaryTextColor)
                if userInput.isEmpty {
                    Text(placeholderText).foregroundColor(.SecondaryTextColor.opacity(0.8)).padding(20).allowsHitTesting(false)
                }
            }.padding(.horizontal)
            Button(action: fetchGuidance) {
                Label("Find Guidance", systemImage: "sparkles")
                    .fontWeight(.semibold).frame(maxWidth: .infinity).padding().background(Color.AccentColor)
                    .foregroundColor(.white).clipShape(Capsule())
            }.padding(.horizontal).disabled(userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
             .opacity(userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.6 : 1.0)
            Spacer()
            VStack {
                Image(systemName: "quote.opening")
                Text("It always seems to find the exact verse I need to hear. Truly a blessing.").italic()
                Text("- App User").font(.caption).fontWeight(.bold)
            }.foregroundColor(.SecondaryTextColor).padding(.bottom, 20)
        }.padding(.top, 40)
    }
    
    private var loadingView: some View {
        VStack(spacing: 20) {
            ProgressView().scaleEffect(1.5).tint(.AccentColor)
            Text("Seeking wisdom for you...").foregroundColor(.SecondaryTextColor).font(.headline)
        }
    }
    
    private var responseView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                VStack {
                    Image(systemName: "heart.text.square.fill")
                        .font(.system(size: 40, weight: .light)).foregroundColor(.AccentColor)
                    Text("A Word For You").font(.largeTitle).fontWeight(.bold).foregroundColor(.PrimaryTextColor)
                    Text("A reflection on your journal entry.").foregroundColor(.SecondaryTextColor)
                }.frame(maxWidth: .infinity).padding(.bottom, 10)
                
                if let guidance = guidanceResponse {
                    guidanceSection(icon: "text.book.closed.fill", title: guidance.verseReference, content: "\"\(guidance.verseText)\"").italic()
                    guidanceSection(icon: "lightbulb.fill", title: "Pastoral Reflection", content: guidance.explanation)
                    guidanceSection(icon: "hands.sparkles.fill", title: "A Gentle Prayer", content: guidance.prayer)
                }

                Button(action: { withAnimation { reset() } }) {
                    Label("New Journal Entry", systemImage: "arrow.uturn.left")
                        .fontWeight(.semibold).frame(maxWidth: .infinity).padding().background(Color.AccentColor.opacity(0.2))
                        .foregroundColor(.AccentColor).clipShape(Capsule())
                }.padding(.top, 20)
            }.padding().padding(.top, 20)
        }
    }

    // --- NEW: Error View ---
    private var errorView: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40, weight: .light))
                .foregroundColor(.red)
            Text("An Error Occurred")
                .font(.title)
                .fontWeight(.bold)
            
            Text(groqService.errorMessage ?? "Something went wrong. Please try again.")
                .foregroundColor(.SecondaryTextColor)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button(action: { withAnimation { reset() } }) {
                Label("Try Again", systemImage: "arrow.uturn.left")
                    .fontWeight(.semibold).frame(maxWidth: .infinity).padding().background(Color.AccentColor)
                    .foregroundColor(.white).clipShape(Capsule())
            }
            .padding()
        }
    }
    
    private func guidanceSection(icon: String, title: String, content: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.headline).foregroundColor(.AccentColor)
            Text(content).font(.body).foregroundColor(.PrimaryTextColor).lineSpacing(5)
        }.padding().background(Color.InputBackgroundColor).clipShape(RoundedRectangle(cornerRadius: 15))
    }
    
    // MARK: - Functions (UPDATED)
    
    private func fetchGuidance() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        
        withAnimation {
            currentState = .loading
        }
        
        // Use a Task to run the async API call
        Task {
            let guidance = await groqService.generateGuidance(for: userInput)
            
            if let guidance = guidance {
                self.guidanceResponse = guidance
                withAnimation {
                    self.currentState = .response
                }
            } else {
                // If guidance is nil, an error occurred. The service already set the error message.
                withAnimation {
                    self.currentState = .error
                }
            }
        }
    }
    
    private func reset() {
        userInput = ""
        guidanceResponse = nil
        groqService.errorMessage = nil
        currentState = .input
    }
}

// MARK: - Custom Colors (Unchanged)
extension Color {
    static let BackgroundColor = Color(UIColor.systemGray6)
    static let InputBackgroundColor = Color(UIColor.systemBackground)
    static let AccentColor = Color(red: 0.3, green: 0.5, blue: 0.7)
    static let PrimaryTextColor = Color(UIColor.label)
    static let SecondaryTextColor = Color(UIColor.secondaryLabel)
}

// MARK: - SwiftUI Preview (Unchanged)
struct AnchorView_Previews: PreviewProvider {
    static var previews: some View {
        AnchorView()
    }
}
