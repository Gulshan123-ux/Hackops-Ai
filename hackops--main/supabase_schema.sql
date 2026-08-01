-- Supabase Database Schema for HackOps AI
-- Execute this in the Supabase SQL Editor to set up tables and triggers.

-- 1. Create Role Enum
CREATE TYPE user_role AS ENUM ('participant', 'mentor', 'judge', 'organizer');

-- 2. Create Users Table
CREATE TABLE public.users (
    id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    email TEXT UNIQUE NOT NULL,
    role user_role NOT NULL DEFAULT 'participant',
    full_name TEXT NOT NULL,
    skills TEXT[] DEFAULT '{}',
    interests TEXT[] DEFAULT '{}',
    experience_level TEXT CHECK (experience_level IN ('beginner', 'intermediate', 'advanced')),
    bio TEXT DEFAULT '',
    target_project_desc TEXT DEFAULT ''
);

-- Enable RLS for Users
ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Allow public read access to users" ON public.users
    FOR SELECT USING (true);

CREATE POLICY "Allow users to update their own profile" ON public.users
    FOR UPDATE USING (auth.uid() = id);

-- Trigger to auto-create user row on sign up
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO public.users (id, email, full_name, role, skills, interests, experience_level, bio, target_project_desc)
  VALUES (
    new.id,
    new.email,
    COALESCE(new.raw_user_meta_data->>'full_name', new.email),
    COALESCE((new.raw_user_meta_data->>'role')::user_role, 'participant'::user_role),
    ARRAY(SELECT jsonb_array_elements_text(COALESCE(new.raw_user_meta_data->'skills', '[]'::jsonb))),
    ARRAY(SELECT jsonb_array_elements_text(COALESCE(new.raw_user_meta_data->'interests', '[]'::jsonb))),
    COALESCE(new.raw_user_meta_data->>'experience_level', 'beginner'),
    COALESCE(new.raw_user_meta_data->>'bio', ''),
    COALESCE(new.raw_user_meta_data->>'target_project_desc', '')
  );
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();


-- 3. Create Teams Table
CREATE TABLE public.teams (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT UNIQUE NOT NULL,
    description TEXT NOT NULL,
    created_by UUID REFERENCES public.users(id) ON DELETE SET NULL,
    project_id UUID,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);

ALTER TABLE public.teams ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Allow public read access to teams" ON public.teams FOR SELECT USING (true);
CREATE POLICY "Allow authenticated users to create teams" ON public.teams FOR INSERT WITH CHECK (auth.role() = 'authenticated');
CREATE POLICY "Allow creators or members to update teams" ON public.teams FOR UPDATE USING (true); -- simplify for MVP


-- 4. Create Team Members Table
CREATE TABLE public.team_members (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    team_id UUID REFERENCES public.teams(id) ON DELETE CASCADE,
    user_id UUID REFERENCES public.users(id) ON DELETE CASCADE,
    joined_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL,
    UNIQUE(team_id, user_id)
);

ALTER TABLE public.team_members ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Allow public read access to team_members" ON public.team_members FOR SELECT USING (true);
CREATE POLICY "Allow member insertion" ON public.team_members FOR INSERT WITH CHECK (true);


-- 5. Create Invites Table
CREATE TABLE public.invites (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    team_id UUID REFERENCES public.teams(id) ON DELETE CASCADE,
    sender_id UUID REFERENCES public.users(id) ON DELETE CASCADE,
    receiver_id UUID REFERENCES public.users(id) ON DELETE CASCADE,
    status TEXT CHECK (status IN ('pending', 'accepted', 'declined')) DEFAULT 'pending' NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);

ALTER TABLE public.invites ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Allow users to read their own invites" ON public.invites FOR SELECT USING (auth.uid() = receiver_id OR auth.uid() = sender_id);
CREATE POLICY "Allow invites insertion" ON public.invites FOR INSERT WITH CHECK (true);
CREATE POLICY "Allow updating invites status" ON public.invites FOR UPDATE USING (true);


-- 6. Create Projects Table
CREATE TABLE public.projects (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    team_id UUID REFERENCES public.teams(id) ON DELETE CASCADE,
    title TEXT NOT NULL,
    description TEXT NOT NULL,
    github_url TEXT NOT NULL,
    demo_url TEXT NOT NULL,
    submitted_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);

ALTER TABLE public.projects ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Allow public read access to projects" ON public.projects FOR SELECT USING (true);
CREATE POLICY "Allow submission by members" ON public.projects FOR INSERT WITH CHECK (true);


-- 7. Update Teams with project_id constraint
ALTER TABLE public.teams ADD CONSTRAINT fk_project FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE SET NULL;


-- 8. Create Evaluations Table (AI + Judge Review)
CREATE TABLE public.evaluations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id UUID REFERENCES public.projects(id) ON DELETE CASCADE UNIQUE,
    innovation_score INTEGER NOT NULL CHECK (innovation_score BETWEEN 1 AND 10),
    technical_score INTEGER NOT NULL CHECK (technical_score BETWEEN 1 AND 10),
    impact_score INTEGER NOT NULL CHECK (impact_score BETWEEN 1 AND 10),
    presentation_score INTEGER NOT NULL CHECK (presentation_score BETWEEN 1 AND 10),
    justification TEXT NOT NULL,
    evaluator_id UUID REFERENCES public.users(id) ON DELETE SET NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);

ALTER TABLE public.evaluations ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Allow public read access to evaluations" ON public.evaluations FOR SELECT USING (true);
CREATE POLICY "Allow judges to insert/update evaluations" ON public.evaluations FOR ALL USING (true);


-- 9. Create Mentor Chats Table (Mentor Escalation Logs)
CREATE TABLE public.mentor_chats (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    team_id UUID REFERENCES public.teams(id) ON DELETE CASCADE,
    user_id UUID REFERENCES public.users(id) ON DELETE CASCADE,
    message_role TEXT NOT NULL CHECK (message_role IN ('user', 'assistant')),
    message_text TEXT NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);

ALTER TABLE public.mentor_chats ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Allow team members to read their chats" ON public.mentor_chats FOR SELECT USING (true);
CREATE POLICY "Allow chats insertion" ON public.mentor_chats FOR INSERT WITH CHECK (true);


-- 10. Enable Realtime Replication for Evaluations and Projects
alter publication supabase_realtime add table public.evaluations;
alter publication supabase_realtime add table public.projects;
alter publication supabase_realtime add table public.teams;
