
export type Json = string | number | boolean | null | { [key: string]: Json | undefined } | Json[]

export type Database = {
  
  "public": {
          Tables: {
            "accounts": {
                  Row: {
                    "category_id": string | null,"channel_name": string,"created_at": string,"id": string,"is_default": boolean,"oauth_token_ref": string | null,"platform": string,"status": string,"target": string | null,"tone": string | null,"user_id": string,"weekly_goal": number
                  }
                  ComputedFields: never
                  Insert: {
                    "category_id"?: string | null,"channel_name": string,"created_at"?: string,"id"?: string,"is_default"?: boolean,"oauth_token_ref"?: string | null,"platform": string,"status"?: string,"target"?: string | null,"tone"?: string | null,"user_id"?: string,"weekly_goal"?: number
                  }
                  Update: {
                    "category_id"?: string | null,"channel_name"?: string,"created_at"?: string,"id"?: string,"is_default"?: boolean,"oauth_token_ref"?: string | null,"platform"?: string,"status"?: string,"target"?: string | null,"tone"?: string | null,"user_id"?: string,"weekly_goal"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "accounts_category_id_fkey"
      columns: ["category_id"]
isOneToOne: false
      referencedRelation: "categories"
      referencedColumns: ["id"]
    }
                  ]
                },"categories": {
                  Row: {
                    "banned_terms": (string)[],"id": string,"keywords_en": (string)[],"keywords_ko": (string)[],"keywords_zh": (string)[],"name": string
                  }
                  ComputedFields: never
                  Insert: {
                    "banned_terms"?: (string)[],"id"?: string,"keywords_en"?: (string)[],"keywords_ko"?: (string)[],"keywords_zh"?: (string)[],"name": string
                  }
                  Update: {
                    "banned_terms"?: (string)[],"id"?: string,"keywords_en"?: (string)[],"keywords_ko"?: (string)[],"keywords_zh"?: (string)[],"name"?: string
                  }
                  Relationships: [
                    
                  ]
                },"project_events": {
                  Row: {
                    "created_at": string,"event": string,"id": string,"project_id": string,"step": number
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"event": string,"id"?: string,"project_id": string,"step": number
                  }
                  Update: {
                    "created_at"?: string,"event"?: string,"id"?: string,"project_id"?: string,"step"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "project_events_project_id_fkey"
      columns: ["project_id"]
isOneToOne: false
      referencedRelation: "projects"
      referencedColumns: ["id"]
    }
                  ]
                },"projects": {
                  Row: {
                    "account_id": string,"category_id": string | null,"created_at": string,"current_step": number,"id": string,"name": string,"status": string,"step_status": NonNullable<Json>,"target_sec": number,"updated_at": string,"user_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "account_id": string,"category_id"?: string | null,"created_at"?: string,"current_step"?: number,"id"?: string,"name": string,"status"?: string,"step_status"?: NonNullable<Json>,"target_sec"?: number,"updated_at"?: string,"user_id"?: string
                  }
                  Update: {
                    "account_id"?: string,"category_id"?: string | null,"created_at"?: string,"current_step"?: number,"id"?: string,"name"?: string,"status"?: string,"step_status"?: NonNullable<Json>,"target_sec"?: number,"updated_at"?: string,"user_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "projects_account_id_user_id_fkey"
      columns: ["account_id","user_id"]
isOneToOne: false
      referencedRelation: "accounts"
      referencedColumns: ["id","user_id"]
    },{
      foreignKeyName: "projects_category_id_fkey"
      columns: ["category_id"]
isOneToOne: false
      referencedRelation: "categories"
      referencedColumns: ["id"]
    }
                  ]
                },"trend_items": {
                  Row: {
                    "captured_at": string,"category_id": string,"id": string,"kr_competition": number | null,"kr_search_growth": number | null,"name": string,"opportunity_score": number | null,"overseas_growth": number | null,"period": string,"sellable": boolean
                  }
                  ComputedFields: never
                  Insert: {
                    "captured_at"?: string,"category_id": string,"id"?: string,"kr_competition"?: number | null,"kr_search_growth"?: number | null,"name": string,"opportunity_score"?: number | null,"overseas_growth"?: number | null,"period": string,"sellable"?: boolean
                  }
                  Update: {
                    "captured_at"?: string,"category_id"?: string,"id"?: string,"kr_competition"?: number | null,"kr_search_growth"?: number | null,"name"?: string,"opportunity_score"?: number | null,"overseas_growth"?: number | null,"period"?: string,"sellable"?: boolean
                  }
                  Relationships: [
                    {
      foreignKeyName: "trend_items_category_id_fkey"
      columns: ["category_id"]
isOneToOne: false
      referencedRelation: "categories"
      referencedColumns: ["id"]
    }
                  ]
                },"user_profiles": {
                  Row: {
                    "default_lang": string | null,"default_len": number,"default_tone": string | null,"email": string | null,"name": string | null,"notify_done": boolean,"notify_weekly": boolean,"subtitle_style": string | null,"user_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "default_lang"?: string | null,"default_len"?: number,"default_tone"?: string | null,"email"?: string | null,"name"?: string | null,"notify_done"?: boolean,"notify_weekly"?: boolean,"subtitle_style"?: string | null,"user_id"?: string
                  }
                  Update: {
                    "default_lang"?: string | null,"default_len"?: number,"default_tone"?: string | null,"email"?: string | null,"name"?: string | null,"notify_done"?: boolean,"notify_weekly"?: boolean,"subtitle_style"?: string | null,"user_id"?: string
                  }
                  Relationships: [
                    
                  ]
                }
          }
          Views: {
            [_ in never]: never
          }
          Functions: {
            [_ in never]: never
          }
          Enums: {
            [_ in never]: never
          }
          CompositeTypes: {
            [_ in never]: never
          }
        }
}

type DatabaseWithoutInternals = Omit<Database, '__InternalSupabase'>

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never = never
> = DefaultSchemaTableNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
  ? (DefaultSchema["Tables"] & DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
      Row: infer R
    }
    ? R
    : never
  : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never
> = DefaultSchemaTableNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
  ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
      Insert: infer I
    }
    ? I
    : never
  : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never
> = DefaultSchemaTableNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
  ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
      Update: infer U
    }
    ? U
    : never
  : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never = never
> = DefaultSchemaEnumNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
  ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
  : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never = never
> = PublicCompositeTypeNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
  ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
  : never

export const Constants = {
  "public": {
          Enums: {
            
          }
        }
} as const
