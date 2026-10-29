// Supabase project for Brewski's Shift List.
// This publishable key is meant to be public: the database only lets it call the app's own functions,
// and every one of them checks the login number first.
window.BREWSKIS_CONFIG = {
  supabaseUrl: "https://xlvukvolpmsgyhtvbtut.supabase.co",
  supabaseAnonKey: "sb_publishable_To80jccXZGOOMIuH0fnV5w_QPaboLBu",
  // Public half of the notification signing key (the private half stays in the database).
  vapidPublicKey: "BC9nFmTSnITwgwoIMUzn7K7yGVle-mjUsVhXc5QEatVTFpLYtOlTI6UN5CJEyQLtiuvMrnQpCiHT6K5gYqACBiY"
};
