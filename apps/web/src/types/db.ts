
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
                },"affiliate_links": {
                  Row: {
                    "bio_no": number | null,"bio_registered_at": string | null,"bio_service": string | null,"created_at": string,"disclosed": boolean,"id": string,"partner_id_ref": string | null,"program": string,"project_id": string,"short_url": string | null,"url": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "bio_no"?: number | null,"bio_registered_at"?: string | null,"bio_service"?: string | null,"created_at"?: string,"disclosed"?: boolean,"id"?: string,"partner_id_ref"?: string | null,"program": string,"project_id": string,"short_url"?: string | null,"url"?: string | null
                  }
                  Update: {
                    "bio_no"?: number | null,"bio_registered_at"?: string | null,"bio_service"?: string | null,"created_at"?: string,"disclosed"?: boolean,"id"?: string,"partner_id_ref"?: string | null,"program"?: string,"project_id"?: string,"short_url"?: string | null,"url"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "affiliate_links_project_id_fkey"
      columns: ["project_id"]
isOneToOne: false
      referencedRelation: "projects"
      referencedColumns: ["id"]
    }
                  ]
                },"api_keys": {
                  Row: {
                    "created_at": string,"id": string,"last4": string | null,"provider": string,"secret_ref": string | null,"status": string,"tested_at": string | null,"user_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"id"?: string,"last4"?: string | null,"provider": string,"secret_ref"?: string | null,"status"?: string,"tested_at"?: string | null,"user_id": string
                  }
                  Update: {
                    "created_at"?: string,"id"?: string,"last4"?: string | null,"provider"?: string,"secret_ref"?: string | null,"status"?: string,"tested_at"?: string | null,"user_id"?: string
                  }
                  Relationships: [
                    
                  ]
                },"bio_items": {
                  Row: {
                    "affiliate_link_id": string | null,"archived_at": string | null,"bio_page_id": string,"id": string,"no": number,"project_id": string | null,"registered_at": string | null,"short_url": string | null,"thumb_url": string | null,"title": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "affiliate_link_id"?: string | null,"archived_at"?: string | null,"bio_page_id": string,"id"?: string,"no": number,"project_id"?: string | null,"registered_at"?: string | null,"short_url"?: string | null,"thumb_url"?: string | null,"title"?: string | null
                  }
                  Update: {
                    "affiliate_link_id"?: string | null,"archived_at"?: string | null,"bio_page_id"?: string,"id"?: string,"no"?: number,"project_id"?: string | null,"registered_at"?: string | null,"short_url"?: string | null,"thumb_url"?: string | null,"title"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "bio_items_affiliate_link_id_fkey"
      columns: ["affiliate_link_id"]
isOneToOne: false
      referencedRelation: "affiliate_links"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "bio_items_bio_page_id_fkey"
      columns: ["bio_page_id"]
isOneToOne: false
      referencedRelation: "bio_pages"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "bio_items_project_id_fkey"
      columns: ["project_id"]
isOneToOne: false
      referencedRelation: "projects"
      referencedColumns: ["id"]
    }
                  ]
                },"bio_pages": {
                  Row: {
                    "account_id": string,"created_at": string,"id": string,"service": string,"url": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "account_id": string,"created_at"?: string,"id"?: string,"service": string,"url"?: string | null
                  }
                  Update: {
                    "account_id"?: string,"created_at"?: string,"id"?: string,"service"?: string,"url"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "bio_pages_account_id_fkey"
      columns: ["account_id"]
isOneToOne: false
      referencedRelation: "accounts"
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
                },"chat_messages": {
                  Row: {
                    "created_at": string,"id": string,"kind": string,"payload": Json | null,"project_id": string,"role": string,"text": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"id"?: string,"kind"?: string,"payload"?: Json | null,"project_id": string,"role": string,"text"?: string | null
                  }
                  Update: {
                    "created_at"?: string,"id"?: string,"kind"?: string,"payload"?: Json | null,"project_id"?: string,"role"?: string,"text"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "chat_messages_project_id_fkey"
      columns: ["project_id"]
isOneToOne: false
      referencedRelation: "projects"
      referencedColumns: ["id"]
    }
                  ]
                },"credit_ledger": {
                  Row: {
                    "created_at": string,"delta": number,"id": string,"idempotency_key": string,"job_id": string | null,"kind": string,"project_id": string | null,"reason": string | null,"user_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"delta": number,"id"?: string,"idempotency_key": string,"job_id"?: string | null,"kind": string,"project_id"?: string | null,"reason"?: string | null,"user_id": string
                  }
                  Update: {
                    "created_at"?: string,"delta"?: number,"id"?: string,"idempotency_key"?: string,"job_id"?: string | null,"kind"?: string,"project_id"?: string | null,"reason"?: string | null,"user_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "credit_ledger_job_id_fkey"
      columns: ["job_id"]
isOneToOne: false
      referencedRelation: "jobs"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "credit_ledger_project_id_fkey"
      columns: ["project_id"]
isOneToOne: false
      referencedRelation: "projects"
      referencedColumns: ["id"]
    }
                  ]
                },"extension_connections": {
                  Row: {
                    "access_expires_at": string,"access_token_hash": string,"created_at": string,"family_id": string,"id": string,"last_heartbeat_at": string | null,"refresh_expires_at": string,"refresh_token_hash": string,"revoked_at": string | null,"user_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "access_expires_at": string,"access_token_hash": string,"created_at"?: string,"family_id": string,"id"?: string,"last_heartbeat_at"?: string | null,"refresh_expires_at": string,"refresh_token_hash": string,"revoked_at"?: string | null,"user_id": string
                  }
                  Update: {
                    "access_expires_at"?: string,"access_token_hash"?: string,"created_at"?: string,"family_id"?: string,"id"?: string,"last_heartbeat_at"?: string | null,"refresh_expires_at"?: string,"refresh_token_hash"?: string,"revoked_at"?: string | null,"user_id"?: string
                  }
                  Relationships: [
                    
                  ]
                },"jobs": {
                  Row: {
                    "attempts": number,"created_at": string,"error": string | null,"extension_id": string | null,"finished_at": string | null,"id": string,"idempotency_key": string,"max_attempts": number,"payload": NonNullable<Json>,"project_id": string,"started_at": string | null,"status": string,"step": number,"type": string
                  }
                  ComputedFields: never
                  Insert: {
                    "attempts"?: number,"created_at"?: string,"error"?: string | null,"extension_id"?: string | null,"finished_at"?: string | null,"id"?: string,"idempotency_key": string,"max_attempts"?: number,"payload"?: NonNullable<Json>,"project_id": string,"started_at"?: string | null,"status"?: string,"step": number,"type": string
                  }
                  Update: {
                    "attempts"?: number,"created_at"?: string,"error"?: string | null,"extension_id"?: string | null,"finished_at"?: string | null,"id"?: string,"idempotency_key"?: string,"max_attempts"?: number,"payload"?: NonNullable<Json>,"project_id"?: string,"started_at"?: string | null,"status"?: string,"step"?: number,"type"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "jobs_extension_id_fkey"
      columns: ["extension_id"]
isOneToOne: false
      referencedRelation: "extension_connections"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "jobs_project_id_fkey"
      columns: ["project_id"]
isOneToOne: false
      referencedRelation: "projects"
      referencedColumns: ["id"]
    }
                  ]
                },"link_clicks": {
                  Row: {
                    "affiliate_link_id": string,"clicked_at": string,"id": string,"platform": string | null,"referrer": string | null,"short_url": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "affiliate_link_id": string,"clicked_at"?: string,"id"?: string,"platform"?: string | null,"referrer"?: string | null,"short_url"?: string | null
                  }
                  Update: {
                    "affiliate_link_id"?: string,"clicked_at"?: string,"id"?: string,"platform"?: string | null,"referrer"?: string | null,"short_url"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "link_clicks_affiliate_link_id_fkey"
      columns: ["affiliate_link_id"]
isOneToOne: false
      referencedRelation: "affiliate_links"
      referencedColumns: ["id"]
    }
                  ]
                },"policy_checks": {
                  Row: {
                    "checked_at": string | null,"checked_by": string | null,"detail": string | null,"id": string,"item": string,"project_id": string,"result": string
                  }
                  ComputedFields: never
                  Insert: {
                    "checked_at"?: string | null,"checked_by"?: string | null,"detail"?: string | null,"id"?: string,"item": string,"project_id": string,"result"?: string
                  }
                  Update: {
                    "checked_at"?: string | null,"checked_by"?: string | null,"detail"?: string | null,"id"?: string,"item"?: string,"project_id"?: string,"result"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "policy_checks_project_id_fkey"
      columns: ["project_id"]
isOneToOne: false
      referencedRelation: "projects"
      referencedColumns: ["id"]
    }
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
                    "account_id": string,"category_id": string | null,"created_at": string,"current_step": number,"id": string,"name": string,"sources_notice_ack_at": string | null,"sources_notice_ack_by": string | null,"sources_shortage_reason": string | null,"status": string,"step_status": NonNullable<Json>,"target_sec": number,"updated_at": string,"user_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "account_id": string,"category_id"?: string | null,"created_at"?: string,"current_step"?: number,"id"?: string,"name": string,"sources_notice_ack_at"?: string | null,"sources_notice_ack_by"?: string | null,"sources_shortage_reason"?: string | null,"status"?: string,"step_status"?: NonNullable<Json>,"target_sec"?: number,"updated_at"?: string,"user_id"?: string
                  }
                  Update: {
                    "account_id"?: string,"category_id"?: string | null,"created_at"?: string,"current_step"?: number,"id"?: string,"name"?: string,"sources_notice_ack_at"?: string | null,"sources_notice_ack_by"?: string | null,"sources_shortage_reason"?: string | null,"status"?: string,"step_status"?: NonNullable<Json>,"target_sec"?: number,"updated_at"?: string,"user_id"?: string
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
                },"publications": {
                  Row: {
                    "account_id": string,"created_at": string,"error": string | null,"id": string,"mode": string,"platform_video_id": string | null,"project_id": string,"published_at": string | null,"retry_count": number,"scheduled_at": string | null,"status": string
                  }
                  ComputedFields: never
                  Insert: {
                    "account_id": string,"created_at"?: string,"error"?: string | null,"id"?: string,"mode": string,"platform_video_id"?: string | null,"project_id": string,"published_at"?: string | null,"retry_count"?: number,"scheduled_at"?: string | null,"status"?: string
                  }
                  Update: {
                    "account_id"?: string,"created_at"?: string,"error"?: string | null,"id"?: string,"mode"?: string,"platform_video_id"?: string | null,"project_id"?: string,"published_at"?: string | null,"retry_count"?: number,"scheduled_at"?: string | null,"status"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "publications_project_id_account_id_fkey"
      columns: ["project_id","account_id"]
isOneToOne: false
      referencedRelation: "projects"
      referencedColumns: ["id","account_id"]
    }
                  ]
                },"renders": {
                  Row: {
                    "clean_status": string,"created_at": string,"cut_map": Json | null,"duration_sec": number | null,"id": string,"job_id": string | null,"mp4_path": string | null,"project_id": string,"upscale_status": string,"version": number
                  }
                  ComputedFields: never
                  Insert: {
                    "clean_status"?: string,"created_at"?: string,"cut_map"?: Json | null,"duration_sec"?: number | null,"id"?: string,"job_id"?: string | null,"mp4_path"?: string | null,"project_id": string,"upscale_status"?: string,"version": number
                  }
                  Update: {
                    "clean_status"?: string,"created_at"?: string,"cut_map"?: Json | null,"duration_sec"?: number | null,"id"?: string,"job_id"?: string | null,"mp4_path"?: string | null,"project_id"?: string,"upscale_status"?: string,"version"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "renders_job_id_fkey"
      columns: ["job_id"]
isOneToOne: false
      referencedRelation: "jobs"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "renders_project_id_fkey"
      columns: ["project_id"]
isOneToOne: false
      referencedRelation: "projects"
      referencedColumns: ["id"]
    }
                  ]
                },"scripts": {
                  Row: {
                    "approved_at": string | null,"created_at": string,"est_sec": number | null,"id": string,"lines": NonNullable<Json>,"project_id": string,"version": number
                  }
                  ComputedFields: never
                  Insert: {
                    "approved_at"?: string | null,"created_at"?: string,"est_sec"?: number | null,"id"?: string,"lines"?: NonNullable<Json>,"project_id": string,"version": number
                  }
                  Update: {
                    "approved_at"?: string | null,"created_at"?: string,"est_sec"?: number | null,"id"?: string,"lines"?: NonNullable<Json>,"project_id"?: string,"version"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "scripts_project_id_fkey"
      columns: ["project_id"]
isOneToOne: false
      referencedRelation: "projects"
      referencedColumns: ["id"]
    }
                  ]
                },"sources": {
                  Row: {
                    "author": string,"checked": boolean,"collected_at": string,"created_at": string,"duration_sec": number | null,"exclude_reason": string | null,"file_deleted_at": string | null,"file_path": string | null,"height": number | null,"id": string,"platform": string,"project_id": string,"purge_after": string,"quarantined": boolean,"rights_basis": string | null,"rights_confirmed_at": string | null,"rights_confirmed_by": string | null,"score": number | null,"title": string | null,"url": string,"used": boolean,"width": number | null
                  }
                  ComputedFields: never
                  Insert: {
                    "author": string,"checked"?: boolean,"collected_at"?: string,"created_at"?: string,"duration_sec"?: number | null,"exclude_reason"?: string | null,"file_deleted_at"?: string | null,"file_path"?: string | null,"height"?: number | null,"id"?: string,"platform": string,"project_id": string,"purge_after": string,"quarantined"?: boolean,"rights_basis"?: string | null,"rights_confirmed_at"?: string | null,"rights_confirmed_by"?: string | null,"score"?: number | null,"title"?: string | null,"url": string,"used"?: boolean,"width"?: number | null
                  }
                  Update: {
                    "author"?: string,"checked"?: boolean,"collected_at"?: string,"created_at"?: string,"duration_sec"?: number | null,"exclude_reason"?: string | null,"file_deleted_at"?: string | null,"file_path"?: string | null,"height"?: number | null,"id"?: string,"platform"?: string,"project_id"?: string,"purge_after"?: string,"quarantined"?: boolean,"rights_basis"?: string | null,"rights_confirmed_at"?: string | null,"rights_confirmed_by"?: string | null,"score"?: number | null,"title"?: string | null,"url"?: string,"used"?: boolean,"width"?: number | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "sources_project_id_fkey"
      columns: ["project_id"]
isOneToOne: false
      referencedRelation: "projects"
      referencedColumns: ["id"]
    }
                  ]
                },"topics": {
                  Row: {
                    "created_at": string,"evidence_urls": (string)[],"id": string,"name": string,"picked": boolean,"product_url": string | null,"project_id": string,"reason": string | null,"round": number
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"evidence_urls"?: (string)[],"id"?: string,"name": string,"picked"?: boolean,"product_url"?: string | null,"project_id": string,"reason"?: string | null,"round"?: number
                  }
                  Update: {
                    "created_at"?: string,"evidence_urls"?: (string)[],"id"?: string,"name"?: string,"picked"?: boolean,"product_url"?: string | null,"project_id"?: string,"reason"?: string | null,"round"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "topics_project_id_fkey"
      columns: ["project_id"]
isOneToOne: false
      referencedRelation: "projects"
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
                },"video_metrics": {
                  Row: {
                    "avg_view_pct": number | null,"date": string,"est_revenue": number | null,"id": string,"link_clicks": number,"publication_id": string,"views": number
                  }
                  ComputedFields: never
                  Insert: {
                    "avg_view_pct"?: number | null,"date": string,"est_revenue"?: number | null,"id"?: string,"link_clicks"?: number,"publication_id": string,"views"?: number
                  }
                  Update: {
                    "avg_view_pct"?: number | null,"date"?: string,"est_revenue"?: number | null,"id"?: string,"link_clicks"?: number,"publication_id"?: string,"views"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "video_metrics_publication_id_fkey"
      columns: ["publication_id"]
isOneToOne: false
      referencedRelation: "publications"
      referencedColumns: ["id"]
    }
                  ]
                },"voice_takes": {
                  Row: {
                    "audio_path": string | null,"created_at": string,"duration_sec": number | null,"id": string,"job_id": string | null,"pauses": Json | null,"project_id": string,"sentences": Json | null,"source": string,"voice_id": string | null,"words": Json | null
                  }
                  ComputedFields: never
                  Insert: {
                    "audio_path"?: string | null,"created_at"?: string,"duration_sec"?: number | null,"id"?: string,"job_id"?: string | null,"pauses"?: Json | null,"project_id": string,"sentences"?: Json | null,"source": string,"voice_id"?: string | null,"words"?: Json | null
                  }
                  Update: {
                    "audio_path"?: string | null,"created_at"?: string,"duration_sec"?: number | null,"id"?: string,"job_id"?: string | null,"pauses"?: Json | null,"project_id"?: string,"sentences"?: Json | null,"source"?: string,"voice_id"?: string | null,"words"?: Json | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "voice_takes_job_id_fkey"
      columns: ["job_id"]
isOneToOne: false
      referencedRelation: "jobs"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "voice_takes_project_id_fkey"
      columns: ["project_id"]
isOneToOne: false
      referencedRelation: "projects"
      referencedColumns: ["id"]
    }
                  ]
                }
          }
          Views: {
            [_ in never]: never
          }
          Functions: {
            "add_direct_source":
{ Args: { "p_author": string,"p_project_id": string,"p_title": string,"p_url": string }; Returns: string
                           },
"approve_step":
{ Args: { "p_project_id": string,"p_step": number }; Returns: Json
                           },
"create_job":
{ Args: { "p_idempotency_key": string,"p_payload"?: Json,"p_project_id": string,"p_type": string }; Returns: Json
                           },
"edit_input_sources":
{ Args: { "p_project_id": string }; Returns: {
              "author": string,
"checked": boolean,
"collected_at": string,
"created_at": string,
"duration_sec": number | null,
"exclude_reason": string | null,
"file_deleted_at": string | null,
"file_path": string | null,
"height": number | null,
"id": string,
"platform": string,
"project_id": string,
"purge_after": string,
"quarantined": boolean,
"rights_basis": string | null,
"rights_confirmed_at": string | null,
"rights_confirmed_by": string | null,
"score": number | null,
"title": string | null,
"url": string,
"used": boolean,
"width": number | null
            }[]
                          SetofOptions: {
        from: "*"
        to: "sources"
        isOneToOne: false
        isSetofReturn: true
      } },
"mark_step_ready":
{ Args: { "p_project_id": string,"p_status": string,"p_step": number }; Returns: Json
                           },
"request_step_change":
{ Args: { "p_project_id": string,"p_step": number }; Returns: Json
                           },
"save_source_use":
{ Args: { "p_notice_ack": boolean,"p_project_id": string,"p_reason": string,"p_uses": Json }; Returns: Json
                           },
"set_source_checks":
{ Args: { "p_project_id": string,"p_source_ids": (string)[] }; Returns: number
                           }
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
